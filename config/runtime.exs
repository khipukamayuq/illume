import Config

if config_env() == :dev do
  config :illume, Illume.Endpoint,
    secret_key_base:
      System.get_env("ILLUME_SECRET_KEY_BASE") ||
        :crypto.strong_rand_bytes(48) |> Base.encode64()
end
