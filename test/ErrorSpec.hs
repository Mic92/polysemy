module ErrorSpec where

import qualified Control.Exception as X
import           Polysemy
import           Polysemy.Async
import           Polysemy.Error
import           Polysemy.Bracket
import           Test.Hspec

newtype MyExc = MyExc String
  deriving (Show, Eq)

instance X.Exception MyExc

spec :: Spec
spec = parallel $ do
  describe "fromException" $ do
    it "should catch exceptions" $ do
      a <-
        runM $ runError $ fromException @MyExc $ do
          _ <- X.throwIO $ MyExc "hello"
          pure ()
      a `shouldBe` (Left $ MyExc "hello")

    it "should not catch non-exceptions" $ do
      a <-
        runM $ runError @MyExc $ fromException @MyExc $ pure ()
      a `shouldBe` Right ()

    it "should happen before Bracket" $ do
      a <-
        runM $ bracketToIOFinal $ runError @MyExc $ do
          onException
            (fromException @MyExc $ do
              _ <- X.throwIO $ MyExc "hello"
              pure ()
            ) $ pure $ error "this exception shouldn't happen"
      a `shouldBe` (Left $ MyExc "hello")
  describe "errorToIOFinal" $ do
    it "should catch errors only for the interpreted Error" $ do
      res1 <- runM $ errorToIOFinal @() $ errorToIOFinal @() $ do
        raise $ throw () `catch` \() -> return ()
      res1 `shouldBe` Right (Right ())
      res2 <- runM $ errorToIOFinal @() $ errorToIOFinal @() $ do
        raise (throw ()) `catch` \() -> return ()
      res2 `shouldBe` Left ()

    it "should propagate errors thrown in 'async'" $ do
      res1 <- runM $ errorToIOFinal @() $ asyncToIOFinal $ do
        a <- async $ throw ()
        await a
      res1 `shouldBe` (Left () :: Either () (Maybe ()))
      res2 <- runM $ errorToIOFinal @() $ asyncToIOFinal $ do
        a <- async $ throw ()
        await a `catch` \() -> return $ Just ()
      res2 `shouldBe` Right (Just ())
