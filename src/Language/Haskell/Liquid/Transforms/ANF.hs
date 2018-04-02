--------------------------------------------------------------------------------
-- | Convert GHC Core into Administrative Normal Form (ANF) --------------------
--------------------------------------------------------------------------------

{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}


module Language.Haskell.Liquid.Transforms.ANF (anormalize) where

import           Prelude                          hiding (error)
import           CoreSyn                          hiding (mkTyArg)
import           CoreUtils                        (exprType)
import qualified DsMonad
import           DsMonad                          (initDsWithModGuts)
import           GHC                              hiding (exprType)
import           HscTypes
import           OccName                          (OccName, mkVarOccFS)
import           Id                               (mkUserLocal)
import           Literal
import           MkCore                           (mkCoreLets)
import           Outputable                       (trace)
import           Var                              (varType, setVarType)
import           Language.Haskell.Liquid.GHC.TypeRep
import           Type                             (mkForAllTys, substTy, mkForAllTys, mkTvSubstPrs, isTyVar)
import           TyCon                            (tyConDataCons_maybe)
-- import           DataCon                          (dataConInstArgTys)
import           VarEnv                           (VarEnv, emptyVarEnv, extendVarEnv, lookupWithDefaultVarEnv)
import           UniqSupply                       (MonadUnique, getUniqueM)
import           Unique                           (getKey)
import           Control.Monad.State.Lazy
import           System.Console.CmdArgs.Verbosity (whenLoud)
import qualified Language.Fixpoint.Misc     as F
import qualified Language.Fixpoint.Types    as F

import           Language.Haskell.Liquid.UX.Config  as UX
import qualified Language.Haskell.Liquid.Misc       as Misc 
import           Language.Haskell.Liquid.GHC.Misc   as GM
import           Language.Haskell.Liquid.Transforms.Rec
import           Language.Haskell.Liquid.Transforms.Rewrite
import           Language.Haskell.Liquid.Types.Errors

import qualified Language.Haskell.Liquid.GHC.SpanStack as Sp
import qualified Language.Haskell.Liquid.GHC.Resugar   as Rs
import           Data.Maybe                       (fromMaybe)
import           Data.List                        (sortBy, (\\))
import           Data.Function                    (on)

--------------------------------------------------------------------------------
-- | A-Normalize a module ------------------------------------------------------
--------------------------------------------------------------------------------
anormalize :: UX.Config -> HscEnv -> ModGuts -> IO [CoreBind]
--------------------------------------------------------------------------------
anormalize cfg hscEnv modGuts = do
  whenLoud $ do
    putStrLn "***************************** GHC CoreBinds ***************************"
    putStrLn $ GM.showCBs untidy (mg_binds modGuts)
    putStrLn "***************************** REC CoreBinds ***************************"
    putStrLn $ GM.showCBs untidy orig_cbs
    putStrLn "***************************** RWR CoreBinds ***************************"
    putStrLn $ GM.showCBs untidy rwr_cbs
  (fromMaybe err . snd) <$> initDsWithModGuts hscEnv modGuts act -- hscEnv m grEnv tEnv emptyFamInstEnv act
    where
      err      = panic Nothing "Oops, cannot A-Normalize GHC Core!"
      act      = Misc.concatMapM (normalizeTopBind γ0) rwr_cbs
      γ0       = emptyAnfEnv cfg
      rwr_cbs  = rewriteBinds cfg orig_cbs
      orig_cbs = transformRecExpr $ mg_binds modGuts
      untidy   = UX.untidyCore cfg

{-
      m        = mgi_module modGuts
      grEnv    = mgi_rdr_env modGuts
      tEnv     = modGutsTypeEnv modGuts

modGutsTypeEnv :: MGIModGuts -> TypeEnv
modGutsTypeEnv mg  = typeEnvFromEntities ids tcs fis
  where
    ids            = bindersOfBinds (mgi_binds mg)
    tcs            = mgi_tcs mg
    fis            = mgi_fam_insts mg
-}

--------------------------------------------------------------------------------
-- | A-Normalize a @CoreBind@ --------------------------------------------------
--------------------------------------------------------------------------------

-- Can't make the below default for normalizeBind as it
-- fails tests/pos/lets.hs due to GHCs odd let-bindings

normalizeTopBind :: AnfEnv -> Bind CoreBndr -> DsMonad.DsM [CoreBind]
normalizeTopBind γ (NonRec x e)
  = do e' <- runDsM $ evalStateT (stitch γ e) (DsST [])
       return [normalizeTyVars $ NonRec x e']

normalizeTopBind γ (Rec xes)
  = do xes' <- runDsM $ execStateT (normalizeBind γ (Rec xes)) (DsST [])
       return $ map normalizeTyVars (st_binds xes')

normalizeTyVars :: Bind Id -> Bind Id
normalizeTyVars (NonRec x e) = NonRec (setVarType x t') $ normalizeForAllTys e
  where t'       = subst msg as as' bt
        msg      = "WARNING unable to renameVars on " ++ GM.showPpr x
        as'      = fst $ splitForAllTys $ exprType e
        (as, bt) = splitForAllTys (varType x)
normalizeTyVars (Rec xes)    = Rec xes'
  where nrec = normalizeTyVars <$> ((\(x, e) -> NonRec x e) <$> xes)
        xes' = (\(NonRec x e) -> (x, e)) <$> nrec

subst :: String -> [TyVar] -> [TyVar] -> Type -> Type
subst msg as as' bt
  | length as == length as'
  = mkForAllTys (mkTyArg <$> as') $ substTy su bt
  | otherwise
  = trace msg $ mkForAllTys (mkTyArg <$> as) bt
  where su = mkTvSubstPrs $ zip as (mkTyVarTys as')

-- | eta-expand CoreBinds with quantified types
normalizeForAllTys :: CoreExpr -> CoreExpr
normalizeForAllTys e = case e of
  Lam b _ | isTyVar b
    -> e
  _ -> mkLams tvs (mkTyApps e (map mkTyVarTy tvs))
  where
  (tvs, _) = splitForAllTys (exprType e)


newtype DsM a = DsM {runDsM :: DsMonad.DsM a}
   deriving (Functor, Monad, MonadUnique, Applicative)

data DsST = DsST { st_binds :: [CoreBind] }

type DsMW = StateT DsST DsM

------------------------------------------------------------------
normalizeBind :: AnfEnv -> CoreBind -> DsMW ()
------------------------------------------------------------------
normalizeBind γ (NonRec x e)
  = do e' <- normalize γ e
       add [NonRec x e']

normalizeBind γ (Rec xes)
  = do es' <- mapM (stitch γ) es
       add [Rec (zip xs es')]
    where
       (xs, es) = unzip xes

--------------------------------------------------------------------
normalizeName :: AnfEnv -> CoreExpr -> DsMW CoreExpr
--------------------------------------------------------------------

-- normalizeNameDebug γ e
--   = liftM (tracePpr ("normalizeName" ++ showPpr e)) $ normalizeName γ e

normalizeName γ e@(Lit l)
  | shouldNormalize l
  = normalizeLiteral γ e
  | otherwise
  = return e

normalizeName γ (Var x)
  = return $ Var (lookupAnfEnv γ x x)

normalizeName _ e@(Type _)
  = return e

normalizeName γ e@(Coercion _)
  = do x     <- lift $ freshNormalVar γ $ exprType e
       add  [NonRec x e]
       return $ Var x

normalizeName γ (Tick tt e)
  = do e'    <- normalizeName (γ `at` tt) e
       return $ Tick tt e'

normalizeName γ e
  = do e'   <- normalize γ e
       x    <- lift $ freshNormalVar γ $ exprType e
       add [NonRec x e']
       return $ Var x

shouldNormalize :: Literal -> Bool
shouldNormalize l = case l of
  LitInteger _ _ -> True
  MachStr _ -> True
  _ -> False

add :: [CoreBind] -> DsMW ()
add w = modify $ \s -> s { st_binds = st_binds s ++ w}

--------------------------------------------------------------------------------
normalizeLiteral :: AnfEnv -> CoreExpr -> DsMW CoreExpr
--------------------------------------------------------------------------------
normalizeLiteral γ e =
  do x <- lift $ freshNormalVar γ $ exprType e
     add [NonRec x e]
     return $ Var x

--------------------------------------------------------------------------------
normalize :: AnfEnv -> CoreExpr -> DsMW CoreExpr
--------------------------------------------------------------------------------
normalize γ e
  | UX.patternFlag γ
  , Just p <- Rs.lift e
  = normalizePattern γ p

normalize γ (Lam x e)
  = do e' <- stitch γ e
       return $ Lam x e'

normalize γ (Let b e)
  = do normalizeBind γ b
       normalize γ e
       -- Need to float bindings all the way up to the top
       -- Due to GHCs odd let-bindings (see tests/pos/lets.hs)

normalize γ (Case e x t as)
  = do n     <- normalizeName γ e
       x'    <- lift $ freshNormalVar γ τx -- rename "wild" to avoid shadowing
       let γ' = incrCaseDepth (extendAnfEnv γ x x')
       as'   <- forM as $ \(c, xs, e') -> liftM (c, xs,) (stitch γ' e')
       as''  <- lift $ expandDefaultCase γ τx as'
       return $ Case n x' t as''
    where τx = GM.expandVarType x

normalize γ (Var x)
  = return $ Var (lookupAnfEnv γ x x)

normalize _ e@(Lit _)
  = return e

normalize _ e@(Type _)
  = return e

normalize γ (Cast e τ)
  = do e' <- normalizeName γ e
       return $ Cast e' τ

normalize γ (App e1 e2)
  = do e1' <- normalize γ e1
       n2  <- normalizeName γ e2
       return $ App e1' n2

normalize γ (Tick tt e)
  = do e' <- normalize (γ `at` tt) e
       return $ Tick tt e'

normalize _ (Coercion c)
  = return $ Coercion c

--------------------------------------------------------------------------------
stitch :: AnfEnv -> CoreExpr -> DsMW CoreExpr
--------------------------------------------------------------------------------
stitch γ e
  = do bs'   <- get
       modify $ \s -> s { st_binds = [] }
       e'    <- normalize γ e
       bs    <- st_binds <$> get
       put bs'
       return $ mkCoreLets bs e'

_mkCoreLets' :: [CoreBind] -> CoreExpr -> CoreExpr
_mkCoreLets' bs e = mkCoreLets bs1 e1
  where
    (e1, bs1)    = GM.tracePpr "MKCORELETS" (e, bs)

--------------------------------------------------------------------------------
normalizePattern :: AnfEnv -> Rs.Pattern -> DsMW CoreExpr
--------------------------------------------------------------------------------
normalizePattern γ p@(Rs.PatBind {}) = do
  -- don't normalize the >>= itself, we have a special typing rule for it
  e1'   <- normalize γ (Rs.patE1 p)
  e2'   <- stitch    γ (Rs.patE2 p)
  return $ Rs.lower p { Rs.patE1 = e1', Rs.patE2 = e2' }

normalizePattern γ p@(Rs.PatReturn {}) = do
  e'    <- normalize γ (Rs.patE p)
  return $ Rs.lower p { Rs.patE = e' }

normalizePattern _ p@(Rs.PatProject {}) =
  return (Rs.lower p)

normalizePattern γ p@(Rs.PatSelfBind {}) = do
  normalize γ (Rs.patE p)

normalizePattern γ p@(Rs.PatSelfRecBind {}) = do
  e'    <- normalize γ (Rs.patE p)
  return $ Rs.lower p { Rs.patE = e' }


--------------------------------------------------------------------------------
expandDefault :: AnfEnv -> Bool 
--------------------------------------------------------------------------------
expandDefault γ = aeCaseDepth γ <= maxCaseExpand γ 

--------------------------------------------------------------------------------
expandDefaultCase :: AnfEnv
                  -> Type
                  -> [(AltCon, [Id], CoreExpr)]
                  -> DsM [(AltCon, [Id], CoreExpr)]
--------------------------------------------------------------------------------
expandDefaultCase γ tyapp zs@((DEFAULT, _ ,_) : _) | expandDefault γ
  = expandDefaultCase' γ tyapp zs

expandDefaultCase γ tyapp@(TyConApp tc _) z@((DEFAULT, _ ,_):dcs)
  = case tyConDataCons_maybe tc of
       Just ds -> do let ds' = ds \\ [ d | (DataAlt d, _ , _) <- dcs]
                     if (length ds') == 1
                      then expandDefaultCase' γ tyapp z
                      else return z
       Nothing -> return z --

expandDefaultCase _ _ z
   = return z

expandDefaultCase' 
  :: AnfEnv -> Type -> [(AltCon, [Id], c)] -> DsM [(AltCon, [Id], c)]
expandDefaultCase' γ t ((DEFAULT, _, e) : dcs)
  | Just dtss <- GM.defaultDataCons t (F.fst3 <$> dcs) = do 
      dcs'    <- forM dtss (cloneCase γ e)
      return   $ sortCases (dcs' ++ dcs)
expandDefaultCase' _ _ z
   = return z 

cloneCase :: AnfEnv -> e -> (DataCon, [Type]) -> DsM (AltCon, [Id], e)
cloneCase γ e (d, ts) = do 
  xs  <- mapM (freshNormalVar γ) ts 
  return (DataAlt d, xs, e)

-- expandDefaultCase' γ (TyConApp tc argτs) z@((DEFAULT, _ ,e) : dcs)
  -- = case tyConDataCons_maybe tc of
       -- Just ds -> do let ds' = ds \\ [ d | (DataAlt d, _ , _) <- dcs]
                     -- dcs'   <- forM ds' $ cloneCase γ argτs e
                     -- return $ sortCases $ dcs' ++ dcs
       -- Nothing -> return z

-- cloneCase :: AnfEnv -> [Type] -> a -> DataCon -> DsM (AltCon, [Id], a)
-- cloneCase γ argτs e d = do 
  -- xs  <- mapM (freshNormalVar γ) (dataConInstArgTys d argτs)
  -- return (DataAlt d, xs, e)

sortCases :: [(AltCon, b, c)] -> [(AltCon, b, c)]
sortCases = sortBy (cmpAltCon `on` F.fst3) 

--------------------------------------------------------------------------------
-- | ANF Environments ----------------------------------------------------------
--------------------------------------------------------------------------------
freshNormalVar :: AnfEnv -> Type -> DsM Id
freshNormalVar γ t = do
  u     <- getUniqueM
  let i  = getKey u
  let sp = Sp.srcSpan (aeSrcSpan γ)
  return (mkUserLocal (anfOcc i) u t sp)

anfOcc :: Int -> OccName
anfOcc = mkVarOccFS . GM.symbolFastString . F.intSymbol F.anfPrefix

data AnfEnv = AnfEnv
  { aeVarEnv    :: VarEnv Id
  , aeSrcSpan   :: Sp.SpanStack
  , aeCfg       :: UX.Config
  , aeCaseDepth :: !Int
  }

instance UX.HasConfig AnfEnv where
  getConfig = aeCfg

emptyAnfEnv :: UX.Config -> AnfEnv
emptyAnfEnv cfg = AnfEnv 
  { aeVarEnv    = emptyVarEnv 
  , aeSrcSpan   = Sp.empty 
  , aeCfg       = cfg 
  , aeCaseDepth = 0
  }

lookupAnfEnv :: AnfEnv -> Id -> Id -> Id
lookupAnfEnv γ x y = lookupWithDefaultVarEnv (aeVarEnv γ) x y

extendAnfEnv :: AnfEnv -> Id -> Id -> AnfEnv
extendAnfEnv γ x y = γ { aeVarEnv = extendVarEnv (aeVarEnv γ) x y }

incrCaseDepth :: AnfEnv -> AnfEnv 
incrCaseDepth γ = γ { aeCaseDepth = 1 + aeCaseDepth γ }

at :: AnfEnv -> Tickish Id -> AnfEnv
at γ tt = γ { aeSrcSpan = Sp.push (Sp.Tick tt) (aeSrcSpan γ)}
