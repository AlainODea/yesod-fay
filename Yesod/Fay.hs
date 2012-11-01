{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
-- | Utility functions for using Fay from a Yesod application.
--
-- This module is intended to be used from your Yesod application, not from
-- your Fay programs.
--
-- We assume a specific file structure, namely that there is a @fay@ folder
-- containing client-side code, and @fay-shared@ containing code to be used by
-- both the client and server.
--
-- The @Language.Fay.Yesod@ module (part of this package, but not exposed) is
-- required by both client and server code. However, since Fay does not
-- currently have package management support, we use a bit of a hack: the TH
-- calls in this package will automatically create the necessary
-- @fay/Language/Fay/Yesod.hs@ file.  Ultimately, we will use a more elegant
-- solution.
--
-- In the future, if this package proves popular enough, Fay support will
-- likely be built into the scaffolding. In the meantime, you must manually
-- integrate it. In order to take advantage of this module, you should modify
-- your Yesod application as follows:
--
-- * Modify your @cabal@ file to include the @fay-shared@ folder when
--   compiling. This can be done by adding a @hs-source-dirs: ., fay-shared@ line
--   to your library section.
--
-- * Create the module @SharedTypes@ in @fay-shared@ and create a @Command@
--   datatype. For an example of what this file should look like, see
--   <https://github.com/snoyberg/yesod-fay/blob/master/sample/fay-shared/SharedTypes.hs>.
--
-- * Add the function @fayFile@ to your @Import@ module. See
--   <https://github.com/snoyberg/yesod-fay/blob/master/sample/Import.hs> for an
--   example.
--
-- * Import the @SharedTypes@ and @Yesod.Fay@ modules into your @Foundation.hs@
--   module. Add an instance of @YesodFay@ for your application. You should set
--   the @YesodFayCommand@ associated type to the @Command@ datatype you
--   created. (You may also need to add a @YesodJquery@ instance.)
--
-- * Add a new route at @/fay-command@ (note: the specific location is a
--   requirement right now) named @FayCommandR@. It must answer @POST@ requests.
--   A basic outline of the implementation is @postFayCommandR =
--   runCommandHandler $ \render command -> case command of ...@.
--
-- * In order to use Fay, add @$(fayFile "MyModule")@ to a widget, and then
--   write the corresponding @fay/MyModule.hs@ file. For an example, see
--   <https://github.com/snoyberg/yesod-fay/blob/master/sample/fay/Home.hs>.
module Yesod.Fay
    ( -- * Typeclass
      YesodFay (..)
      -- * Include Fay programs
    , fayFileProd
    , fayFileReload
    , FayFile
      -- * Commands
    , CommandHandler
    , runCommandHandler
    , Returns
      -- * Reexports
    , YesodJquery (..)
    ) where

import           Control.Monad              (unless)
import           Control.Monad.IO.Class     (liftIO)
import           Data.Aeson                 (decode)
import qualified Data.ByteString.Lazy       as L
import           Data.Data                  (Data)
import           Data.Default               (def)
import           Data.Text                  (pack)
import           Data.Text.Encoding         (encodeUtf8)
import           Data.Text.Lazy.Builder     (fromText)
import           Filesystem                 (createTree)
import           Filesystem.Path.CurrentOS  (directory, encodeString)
import           Language.Fay.Compiler      (compileFile)
import           Language.Fay.Convert       (readFromFay, showToFay)
import           Language.Fay.FFI           (Foreign)
import           Language.Fay.Types         (CompileConfig,
                                             configDirectoryIncludes)
import           Language.Fay.Yesod         (Returns (Returns))
import           Language.Haskell.TH.Syntax (Exp (LitE), Lit (StringL), Q,
                                             qAddDependentFile, qRunIO)
import           System.Exit                (ExitCode (ExitSuccess))
import           System.Process             (rawSystem)
import           Text.Julius                (Javascript (Javascript))
import           Yesod.Core                 (GHandler, GWidget, RepJson,
                                             addScriptEither, getYesod, lift,
                                             lookupPostParam, toWidget)
import           Yesod.Form.Jquery          (YesodJquery, urlJqueryJs)
import           Yesod.Json                 (jsonToRepJson)

langYesodFay :: String
langYesodFay = $(qRunIO $ fmap (LitE . StringL) $ readFile "Language/Fay/Yesod.hs")

writeYesodFay :: IO ()
writeYesodFay = do
    let fp = "fay/Language/Fay/Yesod.hs"
    createTree $ directory fp
    writeFile (encodeString fp) langYesodFay

requireJQuery :: YesodFay master => GWidget sub master ()
requireJQuery = do
    master <- lift getYesod
    addScriptEither $ urlJqueryJs master

mkfp :: String -> FilePath
mkfp name = "fay/" ++ name ++ ".hs"

-- | A function that takes a String giving the Fay module name, and returns an
-- TH splice that generates a @Widget@.
type FayFile = String -> Q Exp

-- | Does a full compile of the Fay code via GHC for type checking, and then
-- embeds the Fay-generated Javascript as a static string. File changes during
-- runtime will not be reflected.
fayFileProd :: FayFile
fayFileProd name = do
    qAddDependentFile fp
    ec <- qRunIO $ do
        writeYesodFay
        rawSystem "ghc" ["-O0", "--make", "-ifay", "-ifay-shared", fp]
    unless (ec == ExitSuccess) $ error $ "Type checking of fay module failed: " ++ name
    eres <- qRunIO $ compileFile config fp
    case eres of
        Left e -> error $ "Unable to compile Fay module \"" ++ name ++ "\": " ++ show e
        Right s -> [|requireJQuery >> toWidget (const $ Javascript $ fromText $ pack s)|]
  where
    fp = mkfp name

config :: CompileConfig
config = def
    { configDirectoryIncludes = ["fay", "fay-shared"]
    }

-- | Performs no type checking on the Fay code. Each time the widget is
-- requested, the Fay code will be compiled from scratch to Javascript.
fayFileReload :: FayFile
fayFileReload name = do
  qRunIO writeYesodFay
  [|
    liftIO (compileFile config $ mkfp name) >>= \eres ->
    (case eres of
        Left e -> error $ "Unable to compile Fay module \"" ++ name ++ "\": " ++ show e
        Right s -> requireJQuery >> toWidget (const $ Javascript $ fromText $ pack s))|]

-- | Type class for applications using Fay.
--
-- We depend on @YesodJquery@ since the generated client-side code uses jQuery
-- for making Ajax calls. We have an associated type stating the command
-- datatype. Since this datatype must be used by both the client and server,
-- you should place its definition in the @fay-shared@ folder.
class ( Data (YesodFayCommand master)
      , Read (YesodFayCommand master)
      , Foreign (YesodFayCommand master)
      , YesodJquery master
      )
  => YesodFay master where
    type YesodFayCommand master

-- | A function provided by the developer describing how to answer individual
-- commands from client-side code.
--
-- Due to restrictions of the type system in Fay, we use a relatively simple
-- approach for encoding the return type. In order to specify this, an extra
-- parameter- @Returns@- is passed around, with a phantom type variable stating
-- the expected return type.
--
-- The first argument to your function is the \"respond\" function: it takes
-- the extra @Returns@ parameter as well as the actual value to be returned,
-- and produces the expected result.
type CommandHandler sub master
    = forall s.
      (forall a. Show a => Returns a -> a -> GHandler sub master s)
   -> YesodFayCommand master
   -> GHandler sub master s

-- | Run a command handler. This provides server-side responses to Fay queries.
runCommandHandler :: YesodFay master
                  => CommandHandler sub master
                  -> GHandler sub master RepJson
runCommandHandler f = do
    mtxt <- lookupPostParam "json"
    case mtxt of
        Nothing -> error "No JSON provided"
        Just txt ->
            case decode (L.fromChunks [encodeUtf8 txt]) >>= readFromFay of
                Nothing -> error $ "Unable to parse input: " ++ show txt
                Just cmd -> f go cmd
  where
    go Returns = jsonToRepJson . showToFay
