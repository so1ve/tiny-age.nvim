# tiny-age.nvim

Transparent editing for age-encrypted files in Neovim.

`tiny-age.nvim` decrypts age files into an `acwrite` buffer and encrypts them again
when the buffer is written. It keeps plaintext out of swap and undo files, writes
ciphertext through a temporary file next to the target, and preserves the original
permissions and ASCII-armor format.

## Why

`age-secret.nvim` is small but filters the buffer through a shell command and has a
hard-coded default recipient. `cryption.nvim` is more capable but exposes an API
rather than transparent file editing. `tiny-age.nvim` focuses on the common case:
open an age file, edit it, and `:write` it safely.

## Requirements

- Neovim 0.10+ (0.13+ when installing with `vim.pack`)
- `age`

Editing agenix secrets also requires `nix-instantiate` (included with Nix).

Passphrase-encrypted age files are not supported because there is no safe,
non-interactive way to choose the recipient used when saving.

## Installation

### `lazy.nvim`

```lua
{
  "so1ve/tiny-age.nvim",
  opts = {
    identities = { vim.fn.expand("~/.config/agenix/identity") },
    recipients = { "age1..." },
  },
}
```

### `vim.pack`

```lua
vim.pack.add({
  { src = "https://github.com/so1ve/tiny-age.nvim" },
}, { confirm = false })

require("tiny-age").setup({
  identities = { vim.fn.expand("~/.config/agenix/identity") },
  recipients = { "age1..." },
})
```

## Usage

Open any file matching a configured suffix:

```sh
nvim secrets/production.age
```

The decrypted text is shown in an `acwrite` buffer. Saving encrypts it again.

Use `:AgeEdit` for encrypted files without the configured suffix:

```vim
:AgeEdit secrets/production.env
```

The same operation is available from Lua:

```lua
require("tiny-age").edit("secrets/production.env")
```

## API

### `setup(opts?)`

Stores configuration and installs the file autocmds and `:AgeEdit` command. Calling
it again replaces the previous configuration.

### `edit(path)`

Opens an encrypted file through the same decrypt/write lifecycle as an automatic
`.age` buffer.

## Configuration

```lua
require("tiny-age").setup({
  age = "age",
  suffixes = { ".age" },
  identities = {},
  recipients = {},
  new_file_armor = true,
})
```

| Option | Default | Description |
| --- | --- | --- |
| `age` | `"age"` | Path to the age executable. |
| `suffixes` | `{ ".age" }` | File suffixes handled automatically. |
| `identities` | `{}` | Identity files passed to every decryption. |
| `recipients` | `{}` | Complete list of public recipients, or a function receiving the absolute target path and returning that list. |
| `new_file_armor` | `true` | Write new files in ASCII-armored format. |

Existing files keep their current format: binary files stay binary and armored files
stay armored.

### agenix

Pass the rules file explicitly:

```lua
require("tiny-age").setup({
  identities = { vim.fn.expand("~/.config/agenix/identity") },
  recipients = require("tiny-age.agenix").from_file("~/nixos/secrets/secrets.nix"),
})
```

`from_file(path)` returns a recipient function. On each save, it evaluates the
target file's `publicKeys` using `nix-instantiate`. Secret names are relative to
the rules file's directory (including `../` paths for targets outside it). For example:

```nix
{
  "homelab/some-secret".publicKeys = [ user homelab ];
}
```

The matching list supplies all encryption recipients for existing and new files.
Rules are evaluated without building derivations. Missing files or entries,
invalid or empty key lists, evaluation errors, and a missing `nix-instantiate`
abort the write and leave the original ciphertext untouched.

### Recipient policy

Saving always requires the complete recipient list. Identities are used only for
decryption. The original recipient list cannot generally be recovered from age
ciphertext, so include every key that needs access in the configured list or the
function's result. `suffixes` and `identities` are lists.

## Safety model

- Decrypted text is stored only in the Neovim buffer.
- Swap and undo files are disabled for encrypted buffers.
- Encryption errors abort the write, leaving the buffer modified.
- Ciphertext is written to a same-directory temporary file, synced, and atomically
  renamed over the target.
- Existing permissions are copied to the temporary file before the rename.
- Files containing NUL bytes after decryption are opened read-only.

## Tests

The integration tests require Neovim, `age`, `age-keygen`, and `nix-instantiate`.

```sh
AGE_BIN="$(command -v age)" nvim --headless -u NONE -i NONE -l tests/tiny-age.lua
```

## License

[MIT](./LICENSE).
