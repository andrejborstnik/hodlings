require! <[ rest timespan ]>
require! 'prelude-ls' : { map, filter, lines, sum, each }
require! 'path'
require! 'fs' : { readFileSync, writeFileSync, existsSync, mkdirSync }

data-url = "https://api.coinmarketcap.com/v1/"
client = rest.wrap require('rest/interceptor/mime')
             .wrap require('rest/interceptor/errorCode')
             .wrap require('rest/interceptor/retry', ), initial: timespan.from-seconds(5).total-milliseconds!
             .wrap require('rest/interceptor/timeout'), timeout: timespan.from-seconds(80).total-milliseconds!
             .wrap require('rest/interceptor/pathPrefix'), prefix: data-url
require! bluebird: Promise
require! <[ ./lib/portfolio ./lib/cli-options ]>

options = cli-options.get-options!

portfolio.ensure-exists options.file
renderer = new options.Renderer(options)

data-dir = path.join __dirname, 'data'
unless existsSync data-dir
  mkdirSync data-dir
lastValuesFile = path.join data-dir, './data.json'

execute = (cb = console.log) ->
  portfolio.load(options.file)
  |> get-latest
  |> (.then renderer.render)
  |> (.then cb)

if options.watch
  display = require(\charm)(process)
    .cursor false

  process.on \exit ->
    display.cursor true
    console.log!
  last-rows = 0

  display-latest-values = ->
    display.up(last-rows - 1).left(999).cursor(true) if last-rows
    execute ->
      display.erase(\down).write(it).cursor(false)
      last-rows := it |> lines |> (.length)
    |> (.catch !->)
  display-latest-values!

  interval = timespan.from-seconds(90).total-milliseconds!
  setInterval display-latest-values, interval
else
  execute!.catch (e) !->
    throw e
    process.exit -1

function find-currency(currencies, id_or_symbol)
  currency = currencies.find (currency) -> currency.id.toLowerCase() == id_or_symbol.toLowerCase()
  if currency
    return currency
  else
    return currencies.find (currency) -> currency.symbol.toLowerCase() == id_or_symbol.toLowerCase()

function write-last-values(details, currencies)
  last-values =
    price_btc_usd: find-currency(currencies, "bitcoin").price_usd
    portfolio: details |> map (entry) -> { id: find-currency(currencies, entry.id).id, price_btc: entry.price-btc }
  writeFileSync lastValuesFile, JSON.stringify last-values

function get-latest(hodlings)
  process-data = (global, currencies, last-values) ->

    bitcoin = find-currency(currencies, "bitcoin")
    ethereum = find-currency(currencies, "ethereum")

    get-value = ({ symbol, amount }) ->
      currency = find-currency(currencies, symbol)

      unless currency? then
        console.error "Unknown coin: #{symbol}"
        return

      fx = options.convert.toLowerCase!
      price = currency["price_#{fx}"] |> parseFloat
      price-btc = currency.price_btc |> parseFloat
      volume = currency["24h_volume_#{fx}"] |> parseFloat

      amount-for-currency = (*) amount
      value = amount-for-currency price
      value-btc = amount-for-currency price-btc
      value-eth = value-btc / ethereum.price_btc

      changes = {}

      change-eth-week = ethereum.percent_change_7d |> parseFloat
      changes.week-vs-eth = (currency.percent_change_7d - change-eth-week) / 100

      change-btc-week = bitcoin.percent_change_7d |> parseFloat
      changes.week-vs-btc = (currency.percent_change_7d - change-btc-week) / 100

      if last-values
        last-currency = last-values.portfolio.find (entry) -> entry.id == find-currency(currencies, symbol).id
        if last-currency
          price_btc_usd = bitcoin.price_usd |> parseFloat
          changes.vs-usd = (price_btc_usd * price-btc) / (last-currency.price_btc * last-values.price_btc_usd) - 1

      return
        count: amount
        value: value
        value-btc: value-btc
        value-eth: value-eth
        price: price
        price-btc: price-btc
        change-vs-usd: changes.vs-usd || 0
        change-week-vs-eth: changes.week-vs-eth || 0
        change-week-vs-btc: changes.week-vs-btc || 0
        id: symbol
        symbol: currency.symbol
        amount: amount
        volume: volume
        market-cap: currency["market_cap_#{fx}"] |> parseFloat
        rank: currency.rank
        currency: currency

    details =
      hodlings
      |> map get-value
      |> filter (?)

    write-last-values(details, currencies)

    grand-total = details |> map (.value) |> sum
    grand-total-eth = details |> map (.value-eth) |> sum
    grand-total-btc = details |> map (.value-btc) |> sum
    details |> each -> it.percentage = it.value / grand-total

    fx = options.convert.toLowerCase!
    flippening = (ethereum["market_cap_#{fx}"] |> parseFloat) /
                 (bitcoin["market_cap_#{fx}"] |> parseFloat)

    ethereum_percentage_of_market_cap = ((ethereum["market_cap_#{fx}"] |> parseFloat) * 100) /
                                        (global["total_market_cap_#{fx}"] |> parseFloat)

    return
      grand-total: grand-total
      grand-total-eth: grand-total-eth
      grand-total-btc: grand-total-btc
      details: details
      flippening: flippening
      ethereum_percentage_of_market_cap: ethereum_percentage_of_market_cap
      global: global

  convert-string =
    | options.convert is /^USD$/i => ""
    | otherwise => "?convert=#{options.convert}"

  make-request = (url) ->
    url + convert-string
    |> client
    |> (.entity!)

  last-values = undefined
  if existsSync lastValuesFile
    last-values = JSON.parse (readFileSync lastValuesFile)

  Promise.join do
    make-request(\global/)
    make-request(\ticker/).then (entity) -> entity
    last-values
    process-data
  .catch (e) !->
    console.error "!!! Error accessing service: #{e}"
    throw e
