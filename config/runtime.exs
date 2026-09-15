import Config

# Random per-boot secret instead of a value committed to git — appropriate
# for a tool with no persistent sessions across restarts (see review
# finding, DECISIONS.md entry 73/74): a restart just logs the one operator
# out, which costs nothing. `ILLUME_SECRET_KEY_BASE` lets it be pinned
# explicitly if ever needed. `config/test.exs` keeps its own static value —
# nothing in the test suite needs cross-run persistence, and a stable value
# there avoids surprising anyone reading that file in isolation.
if config_env() == :dev do
  config :illume, Illume.Endpoint,
    secret_key_base:
      System.get_env("ILLUME_SECRET_KEY_BASE") ||
        :crypto.strong_rand_bytes(48) |> Base.encode64()
end
