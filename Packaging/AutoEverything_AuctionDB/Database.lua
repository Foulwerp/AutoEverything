----------------------------------------------------------------------
-- AutoEverything_AuctionDB
--
-- This companion addon owns the large auction market SavedVariable so price
-- history is written to its own WTF SavedVariables file instead of the main
-- AutoEverything configuration file.
----------------------------------------------------------------------

AutoEverythingAuctionDB = type(AutoEverythingAuctionDB) == "table"
    and AutoEverythingAuctionDB or {}
