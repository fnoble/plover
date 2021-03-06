module Main where

import Test.Tasty
import Test.Tasty.SmallCheck as SC
import Test.Tasty.QuickCheck as QC
import Test.Tasty.HUnit

import Plover.Expressions as Exprs
import Plover.Compile (testWithGcc)

main = defaultMain tests

foo = do
  assert $ 1 == 2

gccCase (label, expr) = testCase label $ do
  merror <- testWithGcc expr
  case merror of
    Just err -> assertFailure (show err)
    Nothing -> return ()

tests :: TestTree
tests = testGroup "Tests" [
  testGroup "Units" $ map gccCase Exprs.good_cases
  ]
