{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Neuron.Zettelkasten
  ( generateSite,
    commandParser,
    run,
    runWith,
    newZettelFile,
  )
where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time
import Development.Shake (Action)
import qualified Neuron.Zettelkasten.Graph as Z
import qualified Neuron.Zettelkasten.Route as Z
import qualified Neuron.Zettelkasten.Store as Z
import Options.Applicative
import Path
import Path.IO
import Relude
import qualified Rib
import qualified Rib.App
import qualified System.Directory as Dir -- TODO: not needed
import System.FilePath (dropTrailingPathSeparator)
import qualified System.FilePattern as FP
import Text.Printf

data App
  = App
      { notesDir :: FilePath,
        cmd :: Command
      }
  deriving (Eq, Show)

data Command
  = -- | Create a new zettel file
    New Text
  | Rib Rib.App.Command
  deriving (Eq, Show)

commandParser :: Parser App
commandParser =
  App
    <$> argument str (metavar "NOTESDIR")
    <*> cmdParser
  where
    cmdParser =
      hsubparser $
        mconcat
          [ command "new" $ info newCommand $ progDesc "Create a new zettel",
            command "rib" $ fmap Rib $ info Rib.App.commandParser $ progDesc "Call rib"
          ]
    newCommand =
      New <$> argument str (metavar "TITLE" <> help "Title of the new Zettel")

run :: Action () -> IO ()
run act = do
  App {..} <- execParser opts
  inputDir <- parseAbsDir =<< Dir.canonicalizePath notesDir
  outputDir <- directoryAside inputDir ".output"
  runWith inputDir outputDir act cmd
  where
    opts =
      info
        (commandParser <**> helper)
        (fullDesc <> progDesc "Zettelkasten based on Rib")
    directoryAside :: Path Abs Dir -> String -> IO (Path Abs Dir)
    directoryAside fp suffix = do
      let baseName = dropTrailingPathSeparator $ toFilePath $ dirname fp
      newDir <- parseRelDir $ baseName <> suffix
      pure $ parent fp </> newDir

runWith :: Path Abs Dir -> Path Abs Dir -> Action () -> Command -> IO ()
runWith srcDir dstDir act = \case
  New tit -> do
    s <- newZettelFile srcDir tit
    putStrLn s
  Rib c -> Rib.App.runWith srcDir dstDir act c

-- | Generate the Zettelkasten site
generateSite ::
  (Z.Route Z.ZettelStore Z.ZettelGraph () -> (Z.ZettelStore, Z.ZettelGraph) -> Action ()) ->
  [Path Rel File] ->
  Action (Z.ZettelStore, Z.ZettelGraph)
generateSite writeHtmlRoute' zettelsPat = do
  zettelStore <- Z.mkZettelStore =<< Rib.forEvery zettelsPat pure
  zettelGraph <- Z.mkZettelGraph zettelStore
  let writeHtmlRoute r = writeHtmlRoute' r (zettelStore, zettelGraph)
  (writeHtmlRoute . Z.Route_Zettel) `mapM_` Map.keys zettelStore
  writeHtmlRoute Z.Route_Index
  pure (zettelStore, zettelGraph)

-- | Create a new zettel file and return its slug
-- TODO: refactor this
newZettelFile :: Path b Dir -> Text -> IO String
newZettelFile inputDir ztitle = do
  zId <- zettelNextIdForToday
  zettelFileName <- parseRelFile $ toString $ zId <> ".md"
  let srcPath = inputDir </> zettelFileName
  doesFileExist srcPath >>= \case
    True ->
      fail $ "File already exists: " <> show srcPath
    False -> do
      writeFile (toFilePath srcPath) $ "---\ntitle: " <> toString ztitle <> "\n---\n\n"
      pure $ toFilePath srcPath
  where
    zettelNextIdForToday :: IO Text
    zettelNextIdForToday = do
      zIdPartial <- dayIndex . toText . formatTime defaultTimeLocale "%y%W%a" <$> getCurrentTime
      zettelFiles <- Dir.listDirectory $ toFilePath $ inputDir
      let nums :: [Int] = sort $ catMaybes $ fmap readMaybe $ catMaybes $ catMaybes $ fmap (fmap listToMaybe . FP.match (toString zIdPartial <> "*.md")) zettelFiles
      case fmap last (nonEmpty nums) of
        Just lastNum ->
          pure $ zIdPartial <> toText @String (printf "%02d" $ lastNum + 1)
        Nothing ->
          pure $ zIdPartial <> "01"
      where
        dayIndex =
          T.replace "Mon" "1"
            . T.replace "Tue" "2"
            . T.replace "Wed" "3"
            . T.replace "Thu" "4"
            . T.replace "Fri" "5"
            . T.replace "Sat" "6"
            . T.replace "Sun" "7"
