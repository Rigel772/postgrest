module Main where

import           Control.Lens               ((^?))
import qualified Data.Aeson.Lens            as L
import qualified Hasql.Decoders             as HD
import qualified Hasql.Encoders             as HE
import qualified Hasql.Pool                 as P
import qualified Hasql.Statement            as H
import qualified Hasql.Transaction          as HT
import qualified Hasql.Transaction.Sessions as HT
import           Text.Heredoc

import Protolude      hiding (get, toS)
import Protolude.Conv (toS)

import PostgREST.QueryBuilder (requestToCallProcQuery)
import PostgREST.Types

import SpecHelper (getEnvVarWithDefault)

import Test.Hspec

main :: IO ()
main = do
  testDbConn <- getEnvVarWithDefault "POSTGREST_TEST_CONNECTION" "postgres://postgrest_test@localhost/postgrest_test"
  pool <- P.acquire (3, 10, toS testDbConn)

  hspec $ describe "QueryCost" $
    context "call proc query" $ do
      it "should not exceed cost when calling setof composite proc" $ do
        cost <- exec pool [str| {"id": 3} |] $
          requestToCallProcQuery (QualifiedIdentifier "test" "get_projects_below") [PgArg "id" "int" True] False Nothing []
        liftIO $
          cost `shouldSatisfy` (< Just 40)

      it "should not exceed cost when calling setof composite proc with empty params" $ do
        cost <- exec pool mempty $
          requestToCallProcQuery (QualifiedIdentifier "test" "getallprojects") [] False Nothing []
        liftIO $
          cost `shouldSatisfy` (< Just 30)

      it "should not exceed cost when calling scalar proc" $ do
        cost <- exec pool [str| {"a": 3, "b": 4} |] $
          requestToCallProcQuery (QualifiedIdentifier "test" "add_them") [PgArg "a" "int" True, PgArg "b" "int" True] True Nothing []
        liftIO $
          cost `shouldSatisfy` (< Just 10)

      context "params=multiple-objects" $ do
        it "should not exceed cost when calling setof composite proc" $ do
          cost <- exec pool [str| [{"id": 1}, {"id": 4}] |] $
            requestToCallProcQuery (QualifiedIdentifier "test" "get_projects_below") [PgArg "id" "int" True] False (Just MultipleObjects) []
          liftIO $ do
            -- lower bound needed for now to make sure that cost is not Nothing
            cost `shouldSatisfy` (> Just 2000)
            cost `shouldSatisfy` (< Just 2100)

        it "should not exceed cost when calling scalar proc" $ do
          cost <- exec pool [str| [{"a": 3, "b": 4}, {"a": 1, "b": 2}, {"a": 8, "b": 7}] |] $
            requestToCallProcQuery (QualifiedIdentifier "test" "add_them") [PgArg "a" "int" True, PgArg "b" "int" True] True Nothing []
          liftIO $
            cost `shouldSatisfy` (< Just 10)


exec :: P.Pool -> ByteString -> SqlQuery -> IO (Maybe Int64)
exec pool input query =
  join . rightToMaybe <$>
  P.use pool (HT.transaction HT.ReadCommitted HT.Read $ HT.statement input $ explainCost query)

explainCost :: SqlQuery -> H.Statement ByteString (Maybe Int64)
explainCost query =
  H.Statement (encodeUtf8 sql) (HE.param $ HE.nonNullable HE.unknown) decodeExplain False
 where
   sql = "EXPLAIN (FORMAT JSON) " <> query
   decodeExplain :: HD.Result (Maybe Int64)
   decodeExplain =
     let row = HD.singleRow $ HD.column $ HD.nonNullable HD.bytea in
     (^? L.nth 0 . L.key "Plan" .  L.key "Total Cost" . L._Integral) <$> row
