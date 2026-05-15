{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)

# Make VintageNetProxy.Fetcher mockable via Mimic. Tests that don't stub it
# get the real implementation (which is what every test except the retry
# suite actually wants).
Mimic.copy(VintageNetProxy.Fetcher)

# Integration tests require the dev/ docker-compose stack to be running.
# Excluded by default; opt in with `mix test --include integration`.
ExUnit.start(exclude: [:integration])
