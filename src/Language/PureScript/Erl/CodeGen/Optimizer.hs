-- |
-- This module optimizes code in the simplified-Erlang intermediate representation.
--
-- The following optimizations are supported:
--
--  * Inlining of (>>=) and ret for the Eff monad
--
module Language.PureScript.Erl.CodeGen.Optimizer (optimize) where

import Prelude.Compat

import Control.Monad.Supply.Class (MonadSupply)

import Language.PureScript.Erl.CodeGen.AST
    ( everywhereOnErl, Erl(EAtomLiteral, EVar, EFunctionDef, EApp), Atom )
import Language.PureScript.Erl.CodeGen.Optimizer.MagicDo
    ( magicDo )
import Language.PureScript.Erl.CodeGen.Optimizer.Blocks
    ( collapseNestedBlocks )
import Language.PureScript.Erl.CodeGen.Optimizer.Common
    ( applyAll, applyAllM )
import Language.PureScript.Erl.CodeGen.Optimizer.Inliner
    ( beginBinds,
      etaConvert,
      evaluateIifes,
      inlineCommonOperators,
      inlineCommonValues,
      singleBegin, collectLists )
import Language.PureScript.Erl.CodeGen.Optimizer.Guards
    ( inlineSimpleGuards )

import qualified Language.PureScript.Erl.CodeGen.Constants as EC
import Language.PureScript.Erl.CodeGen.Optimizer.Unused (removeUnusedFuns)
import Data.Text (Text)

-- |
-- Apply a series of optimizer passes to simplified Javascript code
--
optimize :: MonadSupply m => [(Atom, Int)] ->[Erl] -> m [Erl]
optimize exports es = removeUnusedFuns exports <$> traverse go es
  where
  go erl =
   do
    erl' <- untilFixedPoint (tidyUp . applyAll
      [ 
        inlineCommonValues expander
      , inlineCommonOperators EC.effect EC.effectDictionaries expander
      ]
      ) erl
    untilFixedPoint tidyUp
      =<< untilFixedPoint (return . magicDo expander) 
      erl'

  expander = buildExpander es

  tidyUp :: MonadSupply m => Erl -> m Erl
  tidyUp = applyAllM
    [ pure . collapseNestedBlocks
    , pure . inlineSimpleGuards
    , pure . beginBinds
    , pure . evaluateIifes
    , pure . singleBegin
    , pure . collectLists
    , etaConvert
    ]


untilFixedPoint :: (Monad m, Eq a) => (a -> m a) -> a -> m a
untilFixedPoint f = go
  where
  go a = do
   a' <- f a
   if a' == a then return a' else go a'


-- |
-- Take all top-level ASTs and return a function for expanding top-level
-- variables during the various inlining steps in `optimize`.
--
-- Everything that gets inlined as an optimization is of a form that would
-- have been lifted to a top-level binding during CSE, so for purposes of
-- inlining we can save some time by only expanding variables bound at that
-- level and not worrying about any inner scopes.
--
buildExpander :: [Erl] -> Erl -> Erl
buildExpander = replaceAtoms . foldr go []
  where
  go = \case
    EFunctionDef _ _ name [] ( EApp (EVar "?MEMOIZE") [ e ] ) -> ((name, e) :)
    EFunctionDef _ _ name [] e -> ((name, e) :)
    
    _ -> id
  
  replaceAtoms updates = everywhereOnErl (replaceAtom updates)
  
  replaceAtom updates = \case
    EApp (EAtomLiteral a) [] | Just e <- lookup a updates
      -> e
    EApp (EVar "?MEMOIZE") [ e ] -> e
    other -> other