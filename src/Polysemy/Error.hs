{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# OPTIONS_HADDOCK prune #-}

-- | Description: The effect 'Error' and its interpreters
module Polysemy.Error
  ( -- * Effect
    Error (..)

    -- * Actions
  , throw
  , catch
  , fromEither
  , fromEitherM
  , fromException
  , fromExceptionVia
  , fromExceptionSem
  , fromExceptionSemVia
  , note
  , try
  , tryJust
  , catchJust

    -- * Interpretations
  , runError
  , mapError
  , errorToIOFinal
  ) where

import qualified Control.Exception          as X
import           Control.Monad
import qualified Control.Monad.Trans.Except as E
import           Data.Unique                (Unique, hashUnique, newUnique)
import           GHC.Exts                   (Any)
import           Polysemy
import           Polysemy.Final
import           Polysemy.Internal
import           Polysemy.Internal.Union
import           Unsafe.Coerce              (unsafeCoerce)


------------------------------------------------------------------------------
-- | This effect abstracts the throwing and catching of errors, leaving
-- it up to the interpreter whether to use exceptions or monad transformers
-- like 'E.ExceptT' to perform the short-circuiting mechanism.
data Error e m a where
  -- | Short-circuit the current program using the given error value.
  Throw :: e -> Error e m a
  -- | Recover from an error that might have been thrown in the higher-order
  -- action given by the first argument by passing the error to the handler
  -- given by the second argument.
  Catch :: ∀ e m a. m a -> (e -> m a) -> Error e m a

makeSem ''Error


------------------------------------------------------------------------------
-- | Upgrade an 'Either' into an 'Error' effect.
--
-- @since 0.5.1.0
fromEither
    :: Member (Error e) r
    => Either e a
    -> Sem r a
fromEither (Left e)  = throw e
fromEither (Right a) = pure a
{-# INLINABLE fromEither #-}

------------------------------------------------------------------------------
-- | A combinator doing 'embed' and 'fromEither' at the same time. Useful for
-- interoperating with 'IO'.
--
-- @since 0.5.1.0
fromEitherM
    :: forall e m r a
     . ( Member (Error e) r
       , Member (Embed m) r
       )
    => m (Either e a)
    -> Sem r a
fromEitherM = fromEither <=< embed
{-# INLINABLE fromEitherM #-}


------------------------------------------------------------------------------
-- | Lift an exception generated from an 'IO' action into an 'Error'.
fromException
    :: forall e r a
     . ( X.Exception e
       , Member (Error e) r
       , Member (Embed IO) r
       )
    => IO a
    -> Sem r a
fromException = fromExceptionVia @e id
{-# INLINABLE fromException #-}


------------------------------------------------------------------------------
-- | Like 'fromException', but with the ability to transform the exception
-- before turning it into an 'Error'.
fromExceptionVia
    :: ( X.Exception exc
       , Member (Error err) r
       , Member (Embed IO) r
       )
    => (exc -> err)
    -> IO a
    -> Sem r a
fromExceptionVia f m = do
  r <- embed $ X.try m
  case r of
    Left e  -> throw $ f e
    Right a -> pure a
{-# INLINABLE fromExceptionVia #-}

------------------------------------------------------------------------------
-- | Run a @Sem r@ action, converting any 'IO' exception generated by it into an 'Error'.
fromExceptionSem
    :: forall e r a
     . ( X.Exception e
       , Member (Error e) r
       , Member (Final IO) r
       )
    => Sem r a
    -> Sem r a
fromExceptionSem = fromExceptionSemVia @e id
{-# INLINABLE fromExceptionSem #-}

------------------------------------------------------------------------------
-- | Like 'fromExceptionSem', but with the ability to transform the exception
-- before turning it into an 'Error'.
fromExceptionSemVia
    :: ( X.Exception exc
       , Member (Error err) r
       , Member (Final IO) r
       )
    => (exc -> err)
    -> Sem r a
    -> Sem r a
fromExceptionSemVia f m = do
  r <- controlFinal $ \lower ->
    lower (fmap Right m) `X.catch` (lower . return . Left)
  case r of
    Left e  -> throw $ f e
    Right a -> pure a
{-# INLINABLE fromExceptionSemVia #-}

------------------------------------------------------------------------------
-- | Attempt to extract a @'Just' a@ from a @'Maybe' a@, throwing the
-- provided exception upon 'Nothing'.
note :: Member (Error e) r => e -> Maybe a -> Sem r a
note e Nothing  = throw e
note _ (Just a) = pure a
{-# INLINABLE note #-}

------------------------------------------------------------------------------
-- | Similar to @'catch'@, but returns an @'Either'@ result which is (@'Right' a@)
-- if no exception of type @e@ was @'throw'@n, or (@'Left' ex@) if an exception of type
-- @e@ was @'throw'@n and its value is @ex@.
try :: Member (Error e) r => Sem r a -> Sem r (Either e a)
try m = catch (Right <$> m) (return . Left)
{-# INLINABLE try #-}

------------------------------------------------------------------------------
-- | A variant of @'try'@ that takes an exception predicate to select which exceptions
-- are caught (c.f. @'catchJust'@). If the exception does not match the predicate,
-- it is re-@'throw'@n.
tryJust :: Member (Error e) r => (e -> Maybe b) -> Sem r a -> Sem r (Either b a)
tryJust f m = do
    r <- try m
    case r of
      Right v -> return (Right v)
      Left e -> case f e of
                  Nothing -> throw e
                  Just b  -> return $ Left b
{-# INLINABLE tryJust #-}

------------------------------------------------------------------------------
-- | The function @'catchJust'@ is like @'catch'@, but it takes an extra argument
-- which is an exception predicate, a function which selects which type of exceptions
-- we're interested in.
catchJust :: Member (Error e) r
          => (e -> Maybe b) -- ^ Predicate to select exceptions
          -> Sem r a  -- ^ Computation to run
          -> (b -> Sem r a) -- ^ Handler
          -> Sem r a
catchJust ef m bf = catch m handler
  where
      handler e = case ef e of
                    Nothing -> throw e
                    Just b  -> bf b
{-# INLINABLE catchJust #-}

------------------------------------------------------------------------------
-- | Run an 'Error' effect in the style of
-- 'Control.Monad.Trans.Except.ExceptT'.
runError
    :: Sem (Error e ': r) a
    -> Sem r (Either e a)
runError (Sem m) = Sem $ \k -> E.runExceptT $ m $ \u ->
  case decomp u of
    Left x ->
      liftHandlerWithNat (E.ExceptT . runError) k x
    Right (Weaving (Throw e) _ _ _) -> E.throwE e
    Right (Weaving (Catch main handle) mkT lwr ex) ->
      E.ExceptT $ usingSem k $ do
        ea <- runError $ lwr $ mkT id main
        case ea of
          Right a -> pure . Right $ ex a
          Left e -> do
            ma' <- runError $ lwr $ mkT id $ handle e
            case ma' of
              Left e' -> pure $ Left e'
              Right a -> pure . Right $ ex a
{-# INLINE runError #-}

------------------------------------------------------------------------------
-- | Transform one 'Error' into another. This function can be used to aggregate
-- multiple errors into a single type.
--
-- @since 1.0.0.0
mapError
  :: forall e1 e2 r a
   . Member (Error e2) r
  => (e1 -> e2)
  -> Sem (Error e1 ': r) a
  -> Sem r a
mapError f = interpretH $ \case
  Throw e -> throw $ f e
  Catch action handler ->
    runError (runH' action) >>= \case
      Right x -> pure x
      Left e  -> runH (handler e)
{-# INLINE mapError #-}


data WrappedExc = WrappedExc !Unique Any

instance Show WrappedExc where
  show (WrappedExc uid _) =
    "errorToIOFinal: Escaped opaque exception. Unique hash is: " <>
    show (hashUnique uid) <> "This should only happen if the computation that " <>
    "threw the exception was somehow invoked outside of the argument of 'errorToIOFinal'; " <>
    "for example, if you 'async' an exceptional computation inside of the argument " <>
    "provided to 'errorToIOFinal', and then 'await' on it *outside* of the argument " <>
    "provided to 'errorToIOFinal'. If that or any similar shenanigans seems unlikely, " <>
    "please open an issue on the GitHub repository."

instance X.Exception WrappedExc

catchWithUid :: forall e a. Unique -> IO a -> (e -> IO a) -> IO a
catchWithUid uid m h = X.catch m $ \exc@(WrappedExc uid' e) ->
  if uid == uid' then h (unsafeCoerce e) else X.throwIO exc
{-# INLINE catchWithUid #-}

------------------------------------------------------------------------------
-- | Run an 'Error' effect as an 'IO' 'X.Exception' through final 'IO'. This
-- interpretation is significantly faster than 'runError'.
--
-- /Note/: Effects that aren't interpreted in terms of 'IO'
-- will have local state semantics in regards to 'Error' effects
-- interpreted this way. See 'Final'.
--
-- @since 1.2.0.0
errorToIOFinal
    :: forall e r a
    .  ( Member (Final IO) r
       )
    => Sem (Error e ': r) a
    -> Sem r (Either e a)
errorToIOFinal sem = controlFinal $ \lower -> do
  uid <- newUnique
  catchWithUid @e
    uid
    (lower (Right <$> runErrorAsExcFinal uid sem))
    (\e -> lower $ return $ Left e)
{-# INLINE errorToIOFinal #-}

runErrorAsExcFinal
    :: forall e r a
    .  ( Member (Final IO) r
       )
    => Unique
    -> Sem (Error e ': r) a
    -> Sem r a
runErrorAsExcFinal uid = interpretFinal $ \case
  Throw e   -> embed $ X.throwIO $ WrappedExc uid (unsafeCoerce e)
  Catch m h -> controlWithProcessorS $ \lower ->
    catchWithUid uid (lower m) (\e -> lower (h e))
{-# INLINE runErrorAsExcFinal #-}
