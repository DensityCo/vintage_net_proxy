{:ok, _} = Application.ensure_all_started(:inets)
{:ok, _} = Application.ensure_all_started(:ssl)

# Integration tests require the dev/ docker-compose stack to be running.
# Excluded by default; opt in with `mix test --include integration`.
ExUnit.start(exclude: [:integration])
