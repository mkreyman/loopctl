defmodule Mix.Tasks.ReencryptSecrets do
  @moduledoc """
  Re-encrypts all Cloak-encrypted fields using the current default cipher.

  Run this after rotating the Vault key: move the old key into
  `retired_ciphers` in config, set the new key as `default`, then
  execute this task to migrate all encrypted data.

  ## Usage

      mix reencrypt_secrets

  ## TODO

  - Re-encrypt all Webhook signing secrets (webhook.signing_secret_encrypted)
  - Add progress logging and batch processing for large datasets
  - Support --dry-run flag for validation without writes
  """

  use Mix.Task

  @shortdoc "Re-encrypts all Cloak-encrypted secrets with the current default cipher"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Mix.shell().info("""
    Re-encryption task is a placeholder.

    TODO: Implement re-encryption of Webhook.signing_secret_encrypted
    fields when key rotation is needed. See Cloak documentation for
    Cloak.Vault.migrate/1 pattern.
    """)
  end
end
