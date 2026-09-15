import Config

config :illume, Illume.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "GqaDn2ZjbpvUh4j2Plsnn0NVTFBRgIaj4IfGY8etx3IGS3Ktro273n48JUxKsDOE",
  live_view: [signing_salt: "Ym+/R/j80tMJ8uEYCj46wMQM0SnEoaDR"],
  pubsub_server: Illume.PubSub,
  server: false
