{-# LANGUAGE CPP                #-}
{-# LANGUAGE DefaultSignatures  #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE TypeFamilies       #-}

module Control.Monad.Class.MonadTimer
  ( MonadDelay (..)
  , MonadTimer (..)
  , TimeoutState (..)
  , DiffTime
  , diffTimeToMicrosecondsAsInt
  , microsecondsAsIntToDiffTime
  ) where

import qualified Control.Concurrent as IO
import           Control.Concurrent.Class.MonadSTM.TVar
import qualified Control.Concurrent.STM.TVar as STM
import           Control.Exception (assert)
#if defined(mingw32_HOST_OS)
import           Control.Monad (when)
#endif
import qualified Control.Monad.STM as STM

import           Control.Monad.Cont (ContT (..))
import           Control.Monad.Except (ExceptT (..))
import           Control.Monad.RWS (RWST (..))
import           Control.Monad.Reader (ReaderT (..))
import           Control.Monad.State (StateT (..))
import           Control.Monad.Trans (lift)
import           Control.Monad.Writer (WriterT (..))

import           Data.Functor (void)
import           Data.Kind (Type)
import           Data.Time.Clock (DiffTime, diffTimeToPicoseconds)

#if defined(__GLASGOW_HASKELL__) && !defined(mingw32_HOST_OS) && !defined(__GHCJS__)
import qualified GHC.Event as GHC (TimeoutKey, getSystemTimerManager,
                     registerTimeout, unregisterTimeout, updateTimeout)
#endif

import           Control.Monad.Class.MonadFork
import           Control.Monad.Class.MonadSTM

import qualified System.Timeout as IO

data TimeoutState = TimeoutPending | TimeoutFired | TimeoutCancelled

class Monad m => MonadDelay m where
  threadDelay :: DiffTime -> m ()

  default threadDelay :: MonadTimer m => DiffTime -> m ()
  threadDelay d   = void . atomically . awaitTimeout =<< newTimeout d

class (MonadSTM m, MonadDelay m) => MonadTimer m where
  -- | The type of the timeout handle, used with 'newTimeout', 'readTimeout',
  -- 'updateTimeout' and 'cancelTimeout'.
  --
  data Timeout m :: Type

  -- | Create a new timeout which will fire at the given time duration in
  -- the future.
  --
  -- The timeout will start in the 'TimeoutPending' state and either
  -- fire at or after the given time leaving it in the 'TimeoutFired' state,
  -- or it may be cancelled with 'cancelTimeout', leaving it in the
  -- 'TimeoutCancelled' state.
  --
  -- Timeouts /cannot/ be reset to the pending state once fired or cancelled
  -- (as this would be very racy). You should create a new timeout if you need
  -- this functionality.
  --
  newTimeout     :: DiffTime -> m (Timeout m)

  -- | Read the current state of a timeout. This does not block, but returns
  -- the current state. It is your responsibility to use 'retry' to wait.
  --
  -- Alternatively you may wish to use the convenience utility 'awaitTimeout'
  -- to wait for just the fired or cancelled outcomes.
  --
  -- You should consider the cancelled state if you plan to use 'cancelTimeout'.
  --
  readTimeout    :: Timeout m -> STM m TimeoutState

  -- Adjust when this timer will fire, to the given duration into the future.
  --
  -- It is safe to race this concurrently against the timer firing. It will
  -- have no effect if the timer fires first.
  --
  -- The new time can be before or after the original expiry time, though
  -- arguably it is an application design flaw to move timeouts sooner.
  --
  updateTimeout  :: Timeout m -> DiffTime -> m ()

  -- | Cancel a timeout (unless it has already fired), putting it into the
  -- 'TimeoutCancelled' state. Code reading and acting on the timeout state
  -- need to handle such cancellation appropriately.
  --
  -- It is safe to race this concurrently against the timer firing. It will
  -- have no effect if the timer fires first.
  --
  cancelTimeout  :: Timeout m -> m ()

  -- | Returns @True@ when the timeout is fired, or @False@ if it is cancelled.
  awaitTimeout   :: Timeout m -> STM m Bool
  awaitTimeout t  = do s <- readTimeout t
                       case s of
                         TimeoutPending   -> retry
                         TimeoutFired     -> return True
                         TimeoutCancelled -> return False

  registerDelay :: DiffTime -> m (TVar m Bool)

  default registerDelay :: MonadFork m => DiffTime -> m (TVar m Bool)
  registerDelay = defaultRegisterDelay

  timeout :: DiffTime -> m a -> m (Maybe a)


defaultRegisterDelay :: ( MonadTimer m
                        , MonadFork  m
                        )
                     => DiffTime
                     -> m (TVar m Bool)
defaultRegisterDelay d = do
    v <- atomically $ newTVar False
    t <- newTimeout d
    _ <- forkIO $ atomically (awaitTimeout t >>= writeTVar v)
    return v

--
-- Instances for IO
--

-- | With 'threadDelay' one can use arbitrary large 'DiffTime's, which is an
-- advantage over 'IO.threadDelay'.
--
instance MonadDelay IO where
  threadDelay = go
    where
      go :: DiffTime -> IO ()
      go d | d > maxDelay = do
        IO.threadDelay maxBound
        go (d - maxDelay)
      go d = do
        IO.threadDelay (diffTimeToMicrosecondsAsInt d)

      maxDelay :: DiffTime
      maxDelay = microsecondsAsIntToDiffTime maxBound

#if defined(__GLASGOW_HASKELL__) && !defined(mingw32_HOST_OS) && !defined(__GHCJS__)
instance MonadTimer IO where
  data Timeout IO = TimeoutIO !(STM.TVar TimeoutState) !GHC.TimeoutKey

  readTimeout (TimeoutIO var _key) = STM.readTVar var

  newTimeout = \d -> do
      var <- STM.newTVarIO TimeoutPending
      mgr <- GHC.getSystemTimerManager
      key <- GHC.registerTimeout mgr (diffTimeToMicrosecondsAsInt d)
                                     (STM.atomically (timeoutAction var))
      return (TimeoutIO var key)
    where
      timeoutAction var = do
        x <- STM.readTVar var
        case x of
          TimeoutPending   -> STM.writeTVar var TimeoutFired
          TimeoutFired     -> error "MonadTimer(IO): invariant violation"
          TimeoutCancelled -> return ()

  -- In GHC's TimerManager this has no effect if the timer already fired.
  -- It is safe to race against the timer firing.
  updateTimeout (TimeoutIO _var key) d = do
      mgr <- GHC.getSystemTimerManager
      GHC.updateTimeout mgr key (diffTimeToMicrosecondsAsInt d)

  cancelTimeout (TimeoutIO var key) = do
      STM.atomically $ do
        x <- STM.readTVar var
        case x of
          TimeoutPending   -> STM.writeTVar var TimeoutCancelled
          TimeoutFired     -> return ()
          TimeoutCancelled -> return ()
      mgr <- GHC.getSystemTimerManager
      GHC.unregisterTimeout mgr key
#else
instance MonadTimer IO where
  data Timeout IO = TimeoutIO !(STM.TVar (STM.TVar Bool)) !(STM.TVar Bool)

  readTimeout (TimeoutIO timeoutvarvar cancelvar) = do
    canceled <- STM.readTVar cancelvar
    fired    <- STM.readTVar =<< STM.readTVar timeoutvarvar
    case (canceled, fired) of
      (True, _)  -> return TimeoutCancelled
      (_, False) -> return TimeoutPending
      (_, True)  -> return TimeoutFired

  newTimeout d = do
    timeoutvar    <- STM.registerDelay (diffTimeToMicrosecondsAsInt d)
    timeoutvarvar <- STM.newTVarIO timeoutvar
    cancelvar     <- STM.newTVarIO False
    return (TimeoutIO timeoutvarvar cancelvar)

  updateTimeout (TimeoutIO timeoutvarvar _cancelvar) d = do
    timeoutvar' <- STM.registerDelay (diffTimeToMicrosecondsAsInt d)
    STM.atomically $ STM.writeTVar timeoutvarvar timeoutvar'

  cancelTimeout (TimeoutIO timeoutvarvar cancelvar) =
    STM.atomically $ do
      fired <- STM.readTVar =<< STM.readTVar timeoutvarvar
      when (not fired) $ STM.writeTVar cancelvar True
#endif

  -- | For delays less (or equal) than @maxBound :: Int@ this is exactly the same as
  -- 'STM.registerDaley'; for larger delays it will start a monitoring thread
  -- whcih will update the 'TVar'.
  --
  -- TODO: issue #2184 'registerDelay' relies on 'newTimeout', through
  -- 'defaultRegisterDelay'.  'newTimeout' can overflow an 'Int' (this is
  -- especially easy on 32-bit architectures).
  registerDelay d
      | d <= maxDelay =
        STM.registerDelay (diffTimeToMicrosecondsAsInt d)
      | otherwise =
        defaultRegisterDelay d
    where
      maxDelay :: DiffTime
      maxDelay = microsecondsAsIntToDiffTime maxBound

  timeout = IO.timeout . diffTimeToMicrosecondsAsInt


diffTimeToMicrosecondsAsInt :: DiffTime -> Int
diffTimeToMicrosecondsAsInt d =
    let usec :: Integer
        usec = diffTimeToPicoseconds d `div` 1_000_000 in
    -- Can only represent usec times that fit within an Int, which on 32bit
    -- systems means 2^31 usec, which is only ~35 minutes.
    assert (usec <= fromIntegral (maxBound :: Int)) $
    fromIntegral usec

microsecondsAsIntToDiffTime :: Int -> DiffTime
microsecondsAsIntToDiffTime = (/ 1_000_000) . fromIntegral

--
-- Transfomer's instances
--

instance MonadDelay m => MonadDelay (ContT r m) where
  threadDelay = lift . threadDelay
instance MonadDelay m => MonadDelay (ReaderT r m) where
  threadDelay = lift . threadDelay
instance (Monoid w, MonadDelay m) => MonadDelay (WriterT w m) where
  threadDelay = lift . threadDelay
instance MonadDelay m => MonadDelay (StateT s m) where
  threadDelay = lift . threadDelay
instance MonadDelay m => MonadDelay (ExceptT e m) where
  threadDelay = lift . threadDelay
instance (Monoid w, MonadDelay m) => MonadDelay (RWST r w s m) where
  threadDelay = lift . threadDelay

instance MonadTimer m => MonadTimer (ReaderT r m) where
  newtype Timeout (ReaderT r m) = TimeoutR { unTimeoutR :: Timeout m }
  newTimeout    = lift . fmap TimeoutR . newTimeout
  readTimeout   = WrappedSTM . readTimeout . unTimeoutR
  updateTimeout (TimeoutR t) d = lift $ updateTimeout t d
  cancelTimeout = lift . cancelTimeout . unTimeoutR
  registerDelay = lift . registerDelay
  timeout d f   = ReaderT $ \r -> timeout d (runReaderT f r)

instance (Monoid w, MonadTimer m) => MonadTimer (WriterT w m) where
  newtype Timeout (WriterT w m) = TimeoutW { unTimeoutW :: Timeout m }
  newTimeout    = lift . fmap TimeoutW . newTimeout
  readTimeout   = WrappedSTM . readTimeout . unTimeoutW
  updateTimeout (TimeoutW t) d = lift $ updateTimeout t d
  cancelTimeout = lift . cancelTimeout . unTimeoutW
  registerDelay = lift . registerDelay
  timeout d f   = WriterT $ do
    r <- timeout d (runWriterT f)
    return $ case r of
      Nothing     -> (Nothing, mempty)
      Just (a, w) -> (Just a, w)

instance MonadTimer m => MonadTimer (StateT s m) where
  newtype Timeout (StateT s m) = TimeoutS { unTimeoutS :: Timeout m }
  newTimeout    = lift . fmap TimeoutS . newTimeout
  readTimeout   = WrappedSTM . readTimeout . unTimeoutS
  updateTimeout (TimeoutS t) d = lift $ updateTimeout t d
  cancelTimeout = lift . cancelTimeout . unTimeoutS
  registerDelay = lift . registerDelay
  timeout d f = StateT $ \s -> do
    r <- timeout d (runStateT f s)
    return $ case r of
      Nothing      -> (Nothing, s)
      Just (a, s') -> (Just a, s')

instance (Monoid w, MonadTimer m) => MonadTimer (RWST r w s m) where
  newtype Timeout (RWST r w s m) = TimeoutRWS { unTimeoutRWS :: Timeout m }
  newTimeout    = lift . fmap TimeoutRWS . newTimeout
  readTimeout   = WrappedSTM . readTimeout . unTimeoutRWS
  updateTimeout (TimeoutRWS t) d = lift $ updateTimeout t d
  cancelTimeout = lift . cancelTimeout . unTimeoutRWS
  registerDelay = lift . registerDelay
  timeout d (RWST f) = RWST $ \r s -> do
    res <- timeout d (f r s)
    return $ case res of
      Nothing         -> (Nothing, s, mempty)
      Just (a, s', w) -> (Just a, s', w)


