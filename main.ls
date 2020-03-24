require! <[ rest timespan ]>
require! 'prelude-ls' : { map, filter, lines, sum, each }
require! 'path'
require! 'crypto'
require! 'homedir'
require! <[ chalk ]>
require! 'fs' : { readFileSync, writeFileSync, existsSync, mkdirSync, watchFile }

data-url = "https://api.coinmarketcap.com/v1/"
client = rest.wrap require('rest/interceptor/mime')
             .wrap require('rest/interceptor/errorCode')
             .wrap require('rest/interceptor/retry', ), initial: timespan.from-seconds(5).total-milliseconds!
             .wrap require('rest/interceptor/timeout'), timeout: timespan.from-seconds(80).total-milliseconds!
             .wrap require('rest/interceptor/pathPrefix'), prefix: data-url

data-url-new = "https://pro-api.coinmarketcap.com/v1/"
client-new = rest.wrap require('rest/interceptor/mime')
             .wrap require('rest/interceptor/errorCode')
             .wrap require('rest/interceptor/retry', ), initial: timespan.from-seconds(5).total-milliseconds!
             .wrap require('rest/interceptor/timeout'), timeout: timespan.from-seconds(80).total-milliseconds!
             .wrap require('rest/interceptor/pathPrefix'), prefix: data-url-new

require! bluebird: Promise
require! <[ ./lib/portfolio ./lib/cli-options ]>

options = cli-options.get-options!

portfolio.ensure-main-exists!

unless existsSync options.file
  console.log chalk.red("\nFile #{options.file} not found...")
  return

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

  interval = timespan.from-seconds(600).total-milliseconds!
  setInterval display-latest-values, interval

  watchFile options.file, (curr, prev) ->
    display-latest-values!
else
  execute!.catch (e) !->
    throw e
    process.exit -1

function find-currency(currencies, id_or_symbol)
  currency = currencies.find (currency) -> currency.slug.toLowerCase() == id_or_symbol.toLowerCase()
  return if currency then currency else currencies.find (currency) -> currency.symbol.toLowerCase() == id_or_symbol.toLowerCase()

function write-last-values(details, currencies, totals, hodlings-signature)
  last-values =
    price_btc_usd: find-currency(currencies, "bitcoin").quote[options.convert.toUpperCase!].price
    totals: totals
    hodlings-signature: hodlings-signature
    portfolio: details |> map (entry) -> { id: find-currency(currencies, entry.id).id, price_btc: entry.price-btc }

  writeFileSync lastValuesFile, JSON.stringify last-values, null, 2

function get-latest(hodlings)
  hodlings-signature = crypto.createHash('md5').update(JSON.stringify hodlings).digest("hex")

  process-data = (global, currencies, last-values) ->

    bitcoin = find-currency(currencies, "bitcoin")
    ethereum = find-currency(currencies, "ethereum")

    get-value = ({ coin, amount }) ->
      currency = find-currency(currencies, coin)

      unless currency? then
        console.error "Unknown coin: #{coin}"
        return

      fx = options.convert.toUpperCase!
      price = currency.quote[fx].price |> parseFloat
      price-btc = "0" |> parseFloat
      volume = (currency.quote[fx].volume_24h |> parseFloat) / (bitcoin.quote[fx].volume_24h |> parseFloat)

      amount-for-currency = (*) amount
      value = amount-for-currency price
      value-btc = amount-for-currency price-btc
      value-eth = value-btc / 1

      changes = {}

      change-eth-week = ethereum.quote[fx].percent_change_7d |> parseFloat
      changes.week-vs-eth = (currency.quote[fx].percent_change_7d - change-eth-week) / 100

      change-btc-week = bitcoin.quote[fx].percent_change_7d |> parseFloat
      changes.week-vs-btc = (currency.quote[fx].percent_change_7d - change-btc-week) / 100

      if last-values
        last-currency = last-values.portfolio.find (entry) -> entry.id == find-currency(currencies, coin).id
        if last-currency
          price_btc_usd = "0" |> parseFloat
          changes.vs-usd = 0

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
        id: coin
        symbol: currency.symbol
        amount: amount
        volume: volume
        market-cap: currency.quote[fx].market_cap |> parseFloat
        rank: currency.cmc_rank
        currency: currency

    details =
      hodlings
      |> map get-value
      |> filter (?)

    grand-total = details |> map (.value) |> sum
    grand-total-eth = details |> map (.value-eth) |> sum
    grand-total-btc = details |> map (.value-btc) |> sum
    details |> each -> it.percentage = it.value / grand-total

    fx = options.convert.toLowerCase!
    flippening = (ethereum["market_cap_#{fx}"] |> parseFloat) /
                 (bitcoin["market_cap_#{fx}"] |> parseFloat)

    ethereum_percentage_of_market_cap = 100 * (ethereum["market_cap_#{fx}"] |> parseFloat) /
                                        (global["total_market_cap_#{fx}"] |> parseFloat)

    totals =
      value: grand-total
      currency: fx
      eth: grand-total-eth
      btc: grand-total-btc

    write-last-values(details, currencies, totals, hodlings-signature)

    totals-change = {}

    if last-values && last-values.hodlings-signature && last-values.hodlings-signature == hodlings-signature
      if last-values.totals.currency == fx
        totals-change.fx = grand-total / last-values.totals.value - 1
        totals-change.fx-diff = grand-total - last-values.totals.value
      if last-values.totals.eth
        totals-change.eth = grand-total-eth / last-values.totals.eth - 1
      if last-values.totals.btc
        totals-change.btc = grand-total-btc / last-values.totals.btc - 1

    return
      grand-total: grand-total
      grand-total-eth: grand-total-eth
      grand-total-btc: grand-total-btc
      totals-change: totals-change
      details: details
      flippening: flippening
      ethereum_percentage_of_market_cap: ethereum_percentage_of_market_cap
      global: global

  convert-string =
    | options.convert is /^USD$/i => "?start=1&limit=5000"
    | otherwise => "?convert=#{options.convert}&start=1&limit=5000"

  make-request = (url) ->
    url + convert-string
    |> client
    |> (.entity!)

  make-request-new = (url) ->
      {method: "GET",path: url + convert-string,headers: { "X-CMC_PRO_API_KEY": "key"}}
      |> client-new
      |> (.entity!)

  last-values = undefined
  if existsSync lastValuesFile
    try
      last-values = JSON.parse (readFileSync lastValuesFile)

  Promise.join do
    {}
    make-request-new(\cryptocurrency/listings/latest).then (entity) -> entity.data
    last-values
    process-data
  .catch (e) !->
    console.error "!!! Error accessing service: #{e}"
    throw e
