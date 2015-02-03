{-# LANGUAGE DeriveFunctor, DeriveFoldable, DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances, TypeSynonymInstances #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StandaloneDeriving #-}
module Smash.Parse where
import Smash.Parse.Types
import Smash.Parse.Tests

import Name (Name, runEnv, names)
import qualified Name as N (store, put, get)

import Data.Maybe (fromJust)
import qualified Data.Map.Strict as M

import Control.Applicative ((<$>))
import Control.Monad (foldM)
import Control.Monad.Trans.Either
import Control.Monad.Trans.Class
import Control.Monad.Free
import qualified Data.Traversable as T (Traversable, mapAccumR, sequence)

import Debug.Trace (trace)

store :: UValue -> UnMonad Name
store = N.store
get :: Name -> UnMonad UValue
get = N.get
put :: Name -> UValue -> UnMonad ()
put n v = N.put n v

newVar :: M Name
newVar = store UVar

-- Updates a context and the monad environment given a line.
-- Unification errors for the given line are passed over,
-- so context may be erroneous as well, but parsing can still continue.
parseLine :: Context -> Line -> OuterM Context
parseLine c (LStore LVoid (RHSExpr expr)) = do
  okay <- runEitherT $ typeExpr c expr
  case okay of
    Left err -> trace ("parseLine. " ++ show err) $ return ()
    Right _ -> return ()
  return c
  
parseLine _ (LStore LVoid (RHSBlock _ _ _)) =
  error $ "parseLine. cannot create anonymous block"
parseLine c@(blocks, context) (var := expr) = do
  -- Type the RHS, check context for LHS, bind RHS to LHS, return type ref
  okay <- runEitherT $ do
    rhs <- typeExpr c expr
    lhs <- lift $ case M.lookup var context of
      Nothing -> newVar
      Just n -> return n
    unifyBind lhs rhs
    return lhs
  -- Check result, update context if valid
  case okay of
    Left err -> trace ("parseLine. " ++ show err) $ return c
    Right typeName -> return (blocks, M.insert var typeName context)
parseLine c@(blocks, context) (var :> (B args lines ret)) =
  return (M.insert var (Block args lines ret c) blocks, context)

parseLines :: Context -> [Line] -> OuterM Context
parseLines = foldM parseLine

typeExpr :: Context -> ExprU -> InnerM Name
typeExpr _ (Pure name) = return name
typeExpr c@(blocks, context) (Free expr) =
  case expr of
    ERef var -> lift $
      case M.lookup var context of
        Nothing -> newVar
        Just t -> return t
    EIntLit _ -> lift $ store $ UType (TLit Int)
    EMLit mat -> storeMat c mat
    EMul e1 e2 -> do
      t1 <- typeExpr c e1
      t2 <- typeExpr c e2
      prodName <- lift $ store (UProduct t1 t2)
      propagate prodName
      return prodName
    ESum e1 e2 -> do
      t1 <- typeExpr c e1
      t2 <- typeExpr c e2
      sumName <- lift $ store (USum t1 t2)
      propagate sumName
      return sumName
    ECall name args -> do
      let block = fromJust (M.lookup name blocks)
      argTypes <- mapM (typeExpr c) args
      applyBlock block argTypes

refine :: Name -> UValue -> InnerM ()
refine name val = do
  lift $ put name val
  --propagateAll

propagateAll :: InnerM ()
propagateAll = do
  ns <- lift names
  mapM_ propagate ns

propagate :: Name -> InnerM ()
propagate n = do
  val <- lift $ get n
  case val of
    UEq n' ->
      withValue n' $ \val' -> refine n val'
    UProduct n1 n2 -> do
      -- refine if n1 or n2 has a type
      withValue n1 $ \val' -> unifyProduct val' n n1 n2
      withValue n2 $ \val' -> unifyProduct val' n n1 n2
    USum n1 n2 -> do
      -- refine if n1 or n2 has a type
      withValue n1 $ \val' -> unifySum val' n n1 n2
      withValue n2 $ \val' -> unifySum val' n n1 n2
    _ -> return ()

withValue :: Name -> (UValue -> InnerM ()) -> InnerM ()
withValue name fn = do
  val <- lift (get name)
  case val of
    UVar -> return ()
    _ -> fn val

unifyBaseType :: Name -> Name -> InnerM ()
unifyBaseType n1 n2 = do
  -- TODO get rid of this list match
  TMatrix _ bt1 <- matchMatrix n1
  TMatrix _ bt2 <- matchMatrix n2
  unifyBind bt1 bt2

unifyLit :: BaseType -> Name -> InnerM ()
unifyLit bt name = do
  btn <- lift $ store $ UType $ TLit bt
  unifyBind name btn

unifyProduct :: UValue -> Name -> Name -> Name -> InnerM ()
unifyProduct (UType (TMatrix _ _)) product n1 n2 = 
  unifyMatrixProduct product n1 n2
unifyProduct (UType (TLit bt)) product n1 n2 =
  mapM_ (unifyLit bt) [product, n1, n2]
unifyProduct _ _ _ _ = return ()

unifySum :: UValue -> Name -> Name -> Name -> InnerM ()
unifySum (UType (TMatrix _ _)) sum n1 n2 = do
  unifyMatrixSum sum n1 n2
unifySum (UType (TLit bt)) sum n1 n2 =
  mapM_ (unifyLit bt) [sum, n1, n2]

-- Matrix Unification Utilities
unifyMatrixProduct :: Name -> Name -> Name -> InnerM ()
unifyMatrixProduct prod t1 t2 = do
  unifyInner t1 t2
  unifyRows t1 prod
  unifyCols t2 prod

unifyMatrixSum :: Name -> Name -> Name -> InnerM ()
unifyMatrixSum sum n1 n2 = do
  unifyMatrixDim n1 n2
  unifyMatrixDim n1 sum
unifyMatrixDim :: Name -> Name -> InnerM ()
unifyMatrixDim n1 n2 = do
  unifyRows n1 n2
  unifyCols n1 n2
  unifyBaseType n1 n2

-- Core Unification Functions
type Bindings = [(Name, Name)]

unifyBind :: Name -> Name -> InnerM ()
unifyBind n1 n2 = do
  bindings <- unify n1 n2
  mapM_ (uncurry update) bindings
 where
  update n1 n2 = do
    v2 <- lift $ get n2
    case v2 of
      -- TODO propagate substitutions?
      UVar -> refine n1 (UEq n2)
      _ -> refine n1 v2

unify :: Name -> Name -> InnerM Bindings
unify n1 n2 = do
  v1 <- lift $ get n1
  v2 <- lift $ get n2
  unifyOne n1 v1 n2 v2

unifyOne :: Name -> UValue -> Name -> UValue -> InnerM Bindings
unifyOne n1 UVar n2 _ = right $ [(n1, n2)]
unifyOne n1 t n2 UVar = unifyOne n2 UVar n1 t
-- The consequences of such a unification are handled elsewhere
unifyOne n1 (UProduct _ _) n2 _ = do
  return [(n1, n2)]
unifyOne n1 (USum _ _) n2 _ = do
  return [(n1, n2)]
unifyOne n1 (UType e1) n2 (UType e2) = do
  assert (tagEq e1 e2) [n1, n2] $
    "unifyOne. expr types don't match: " ++ show e1 ++ ", " ++ show e2
  bs <- unifyMany [n1, n2] (children e1) (children e2)
  return $ (n1, n2) : bs
unifyOne n1 (UExpr e1) n2 (UExpr e2) = do
  assert (tagEq e1 e2) [n1, n2] $
    "unifyOne. expr values don't match: " ++ show e1 ++ ", " ++ show e2
  bs <- unifyMany [n1, n2] (children e1) (children e2)
  return $ (n1, n2) : bs
unifyOne n1 v1 n2 v2 = left $ UError [n1, n2] $
  "unifyOne. value types don't match: " ++ show v1 ++ ", " ++ show v2

-- First argument: provenance (for error reporting)
-- second, third: list of names to unify
unifyMany :: [Name] -> [Name] -> [Name] -> InnerM Bindings
unifyMany from ns1 ns2 = do
  assert (length ns1 == length ns2) from $
    "unifyMany. type arg list lengths don't match: "
      ++ show ns1 ++ ", " ++ show ns2
  concat <$> mapM (uncurry unify) (zip ns1 ns2)

extend :: TypeContext -> [(Variable, Name)] -> TypeContext
extend context bindings = foldr (uncurry M.insert) context bindings

applyBlock :: Block -> [Name] -> InnerM Name
applyBlock (Block params body ret (blocks, context)) args = do
  let bs' = extend context (zip params args)
  c2 <- lift $ parseLines (blocks, bs') body
  typeExpr c2 ret

-- Matrix Unificaiton Utilities
matrixVar :: M Name
matrixVar = do
  typeVar <- store UVar
  rowsVar <- store UVar
  colsVar <- store UVar
  store $ UType $ TMatrix (Dim rowsVar colsVar) typeVar

matchMatrix :: Name -> InnerM Type
matchMatrix name = do
  val <- lift $ get name
  case val of
    UVar -> do
      mvar <- lift $ matrixVar
      unifyBind name mvar
      matchMatrix name
    UProduct n1 n2 -> do
      mvar <- lift matrixVar
      unifyBind name mvar
      unifyMatrixProduct name n1 n2
      matchMatrix name
    USum n1 n2 -> do
      mvar <- lift matrixVar
      unifyBind name mvar
      unifyMatrixSum name n1 n2
      matchMatrix name
    UType t@(TMatrix _ _) ->
      return t
    _ -> left $ UError [name] "not a matrix"

getDim :: (Dim -> Name) -> Name -> InnerM Name
getDim fn name = do
  (TMatrix dim _) <- matchMatrix name
  return (fn dim)

unifyInner :: Name -> Name -> InnerM ()
unifyInner n1 n2 = do
  c1 <- getDim dimColumns n1
  r2 <- getDim dimRows n2
  unifyBind c1 r2

unifyRows :: Name -> Name -> InnerM ()
unifyRows n1 n2 = do
  r1 <- getDim dimRows n1
  r2 <- getDim dimRows n2
  unifyBind r1 r2

unifyCols :: Name -> Name -> InnerM ()
unifyCols n1 n2 = do
  c1 <- getDim dimColumns n1
  c2 <- getDim dimColumns n2
  unifyBind c1 c2

-- Unification Utilities
assert :: Bool -> [Name] -> String -> InnerM ()
assert True _ _ = return ()
assert False info str = left $ UError info ("assert failure: " ++ str)

tagEq :: (Functor f, Eq (f ())) => f a -> f a -> Bool
tagEq t1 t2 = fmap (const ()) t1 == fmap (const ()) t2

children :: (T.Traversable t) => t a -> [a]
children t = fst $ T.mapAccumR step [] t
 where
  step list child = (child : list, ())

-- Expression Flattening Utilities
storeMat :: Context -> Mat -> InnerM Name
storeMat c (Mat bt (Dim rows cols) _) = do
  typeVar <- lift $ store $ UType (TLit bt)
  rowsVar <- lift $ storeExpr rows
  colsVar <- lift $ storeExpr cols
  lift $ store $ UType (TMatrix (Dim rowsVar colsVar) typeVar)


storeExpr :: ExprU -> M Name
storeExpr e = iterM (\f -> T.sequence f >>= (store . UExpr)) e


-- Testing
emptyContext :: Context
emptyContext = (M.fromList [], M.fromList [])

chk :: [Line] -> IO ()
chk x = 
  let ((blocks, context), vars) = runEnv $ parseLines emptyContext x
  in do
    mapM_ print (M.toList context)
    putStrLn "-----------"
    mapM_ print (M.toList vars)
