import Config

config :illume, Illume.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "dev_secret_key_base_at_least_64_bytes_long_padding_padding_pad",
  live_view: [signing_salt: "illumedevsalt"],
  pubsub_server: Illume.PubSub,
  server: false
