import
  std/[strformat, strutils],
  knobby/discord_rpc

const
  AuthorizeTimeoutMs = 300_000

proc main() =
  ## One-time Discord RPC authorization for knobby's Discord mute button.
  ## Expects the credentials file to already hold clientId and clientSecret
  ## from an application created at discord.com/developers/applications.
  if not discordCredsExist():
    echo fmt"No credentials file at {discordCredsPath()}."
    echo "Create a Discord application, then write the file:"
    echo """  {"clientId": "<app id>", "clientSecret": "<app secret>"}"""
    quit(1)
  var creds = loadDiscordCreds()
  if creds.clientId.len == 0 or creds.clientSecret.len == 0:
    echo fmt"clientId or clientSecret missing in {discordCredsPath()}."
    quit(1)
  let client = connectDiscordRpc()
  client.recvTimeoutMs = AuthorizeTimeoutMs
  discard client.handshake(creds.clientId)
  echo fmt"""Requesting scopes: {OauthScopes.join(" ")}"""
  echo "Approve the authorization popup inside Discord..."
  let code = client.authorize(creds.clientId)
  echo "Approved. Exchanging the code for tokens..."
  exchangeAuthCode(creds, code)
  discard client.authenticate(creds.accessToken)
  client.close()
  echo fmt"Authorized. Tokens saved to {discordCredsPath()}."
  echo "Button 8 is ready."

when isMainModule:
  main()
