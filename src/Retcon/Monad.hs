--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

-- | Description: Monad for retcon handlers.
--
-- This module implements the monad in which the main "handler" actions
-- execute. This monad provides the following effects:
--
-- - Error handling
-- - Logging
-- - Accessing configuration
-- - I/O

{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}

module Retcon.Monad (
    RetconMonad,
    RetconHandler,
    RetconAction,
    runRetconMonad,
    runRetconMonad',
    runRetconHandler,
    runRetconAction,
    RetconState(..),
    retconState,
    retconStore,
    retconOptions,
    carefully,
    getRetconState,
    getActionState,
    whenVerbose,
    ) where

import Control.Applicative
import Control.Exception.Enclosed
import qualified Control.Lens as L
import Control.Lens.Operators
import Control.Lens.TH
import Control.Monad.Base
import Control.Monad.Except
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.Trans.Control
import Data.Bifunctor

import Retcon.DataSource hiding (RetconAction)
import Retcon.Error
import Retcon.Options
import Retcon.Store

-- * Retcon monad

-- $ Retcon handlers (i.e. actions which process and response to an event) are
-- actions in the 'RetconHandler' monad.

-- | State held in the reader part of the 'RetconHandler' monad.
data RetconState s = RetconState
    { _retconOptions :: RetconOptions
    , _retconState   :: [InitialisedEntity]
    , _retconStore   :: s
    }
makeLenses ''RetconState

-- | Monad transformer stack used in the 'RetconHandler' monad.
type RetconHandlerStack s l = ReaderT (RetconState s, l) (ExceptT RetconError (LoggingT IO))

-- | Monad for the retcon system.
--
-- This monad provides access to an environment containing the "global" state
-- of the retcon system and the "local" state of the current action; error
-- handling through exceptions; logging; and I/O.
newtype RetconMonad s l a =
    RetconMonad {
        unRetconMonad :: (RetconHandlerStack s l) a
    }
  deriving (Functor, Applicative, Monad, MonadIO, MonadLogger,
            MonadReader (RetconState s, l), MonadError RetconError,
            MonadBase IO)

-- | MonadBaseControl used to catch IO exceptions
instance MonadBaseControl IO (RetconMonad s l) where
    newtype StM (RetconMonad s l) a = StHandler {
        unStHandler :: StM (RetconHandlerStack s l) a
    }

    -- Unwrap the bits in our monad to get to the base.
    liftBaseWith f = RetconMonad . liftBaseWith $ \r ->
        f $ liftM StHandler . r . unRetconMonad

    -- Wrap things back up into our monad.
    restoreM       = RetconMonad . restoreM . unStHandler

-- ** Evaluators

-- | Execute an action in the 'RetconMonad' monad.
runRetconMonad :: RetconOptions
               -> [InitialisedEntity]
               -> s
               -> l
               -> RetconMonad s l a
               -> IO (Either RetconError a)
runRetconMonad opt state store l =
    runLogging .
    runExceptT .
    flip runReaderT (st, l) . unRetconMonad
  where
    st = RetconState opt state store
    runLogging = case opt ^. optLogging of
      LogStderr -> runStderrLoggingT
      LogStdout -> runStdoutLoggingT
      LogNone   -> (`runLoggingT` \_ _ _ _ -> return ())

-- | TODO: Document this function, also why does this ignore config?
runRetconMonad' :: RetconOptions
                -> RetconConfig
                -> s
                -> l
                -> RetconMonad s l a
                -> IO (Either RetconError a)
runRetconMonad' opt _ store l = do
    let state = []
    runRetconMonad opt state store l

-- * Handler monad

type RetconHandler s a = RetconMonad s () a

-- | Run an action in the 'RetconHandler' monad (aka the 'RetconMonad' with
-- '()' local state).
runRetconHandler :: RetconOptions
                 -> [InitialisedEntity]
                 -> s
                 -> RetconHandler s a
                 -> IO (Either RetconError a)
runRetconHandler opt state store = runRetconMonad opt state store ()

-- * Action monad

type RetconAction l a = RetconMonad ROToken l a

-- | Run an action in the 'RetconAction' monad (aka the 'RetconMonad' with
-- read-only storage).
--
-- Errors which occur in the action are handled and will not propagate up into
-- the parent handler.
runRetconAction :: StoreToken s
                => l
                -> RetconAction l a
                -> RetconHandler s (Either RetconError a)
runRetconAction l =
    -- Restrict store and add the local state.
    RetconMonad . withReaderT localise . unRetconMonad .
    -- Do exception and error handling.
    handle . handleAny (throwError . RetconError)
  where
    localise = bimap (retconStore %~ restrictToken) (const l)

    -- | Handle any errors in an action, pulling them into the monad.
    handle :: (Functor m, MonadError e m) => m v -> m (Either e v)
    handle a = (Right <$> a) `catchError` (return . Left)

-- * Monad operations

-- | Get the retcon component of the environment.
getRetconState :: RetconMonad s l (RetconState s)
getRetconState = asks fst

-- | Get the action-specific component of the environment.
getActionState :: RetconMonad s l l
getActionState = asks snd

-- | Run an action in 'RetconHandler', catching any exceptions and propagating
-- them as 'RetconError's.
carefully :: RetconMonad s l a -> RetconMonad s l a
carefully = handleAny (throwError . RetconError)

-- | Do something when the verbose option is set
whenVerbose :: (MonadReader (RetconState x, y) m) => m () -> m ()
whenVerbose f = do
    verbose <- L.view (L._1 . retconOptions . optVerbose)
    when verbose f
