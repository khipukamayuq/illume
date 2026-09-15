import Config

# Bandit, not the default Cowboy2Adapter — plug_cowboy isn't a dependency
# (see DECISIONS.md entry 55's research: Bandit is pure Elixir, no C/NIF).
config :illume, Illume.Endpoint, adapter: Bandit.PhoenixAdapter

import_config "#{config_env()}.exs"
