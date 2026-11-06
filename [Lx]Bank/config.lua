BANK_CFG = {
  startCash = 2500, startBank = 0,            -- first login of a new account
  maxCash = 2000000000,                       -- MTA's own money limit is 2,147,483,647
  maxBank = 1000000000000,
  maxTransfer = 50000000,                     -- per transfer
  feePercent = 0.5,                           -- transfer fee paid by the sender (0 = free)
  atmRange = 3.5,
  -- !! Check these positions in-game (/getpos in a debug resource) and replace them with your real ATMs/banks.
  atms = {
    { x = 1481.0, y = -1766.5, z = 18.8,  int = 0, dim = 0, name = "City Hall ATM" },
    { x = 2105.5, y = -1806.5, z = 13.55, int = 0, dim = 0, name = "Pizza Stack ATM" },
    { x = 2229.0, y = -1721.5, z = 13.55, int = 0, dim = 0, name = "Ganton ATM" },
  },
}
