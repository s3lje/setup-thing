#!/usr/bin/env bash
#
# bootstrap.sh - set up a fresh macOS (or Linux) machine.
#
#   - Homebrew (on both macOS and Linux, so there is a single code path)
#   - C/C++, Rust, Node/JS, Python toolchains
#   - Neovim + your LazyVim config, plugins, treesitter parsers, Mason LSP servers
#   - Zsh + Oh My Zsh + Powerlevel10k + your zshrc, plugins and CLI tools
#   - Nerd Font, Firefox as the default browser
#
# Safe to re-run: every step skips what is already done.
# Written to work with macOS's ancient bash 3.2 (no mapfile, no assoc arrays).
#
# Usage:  bash bootstrap.sh        (run as your normal user, NOT with sudo)

set -o pipefail

# ----------------------------------------------------------------------------
# Config - edit these
# ----------------------------------------------------------------------------
NVIM_REPO="https://github.com/s3lje/nvim-config"
ZSH_REPO="https://github.com/s3lje/ohmyzsh-config"
DOTFILES_DIR="$HOME/.dotfiles"

# Formulae installed on both macOS and Linux
CORE_FORMULAE=(git wget jq neovim tree-sitter-cli ripgrep fd fzf lazygit bat eza zoxide)
LANG_FORMULAE=(cmake ninja pkgconf clang-format node pnpm python uv pipx)
SHELL_FORMULAE=(atuin direnv mise tmux btop yazi stow)

# Platform-specific formulae
MACOS_FORMULAE=(trash)
LINUX_FORMULAE=(llvm gdb valgrind trash-cli)

# Anything extra you want (e.g. go, ruby, openjdk for other LazyVim language extras)
EXTRA_FORMULAE=()

# Mason packages (LSP servers, formatters, linters, debuggers).
# Unknown names are skipped with a warning, so this list is safe to edit freely.
MASON_PACKAGES=(
  # C / C++ / CMake
  clangd clang-format codelldb neocmakelsp
  # Rust
  rust-analyzer
  # Python
  pyright ruff debugpy
  # HTML / CSS / JS / TS
  html-lsp css-lsp emmet-language-server tailwindcss-language-server
  vtsls eslint-lsp prettier js-debug-adapter
  # Config / data / misc
  json-lsp yaml-language-server taplo lua-language-server stylua
  bash-language-server shfmt shellcheck marksman markdownlint-cli2 markdown-toc
)

# Treesitter parsers to pre-install
TS_PARSERS=(
  bash c cpp cmake css diff git_config gitcommit gitignore html javascript jsdoc
  json lua luadoc make markdown markdown_inline ninja python query regex rst rust
  scss toml tsx typescript vim vimdoc yaml
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
WARNINGS=()
OS=""
PM=""
BREW_BIN=""
INSTALLED=""

c_blue=$'\033[1;34m'; c_yel=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_blue" "$c_off" "$*"; }
warn() { printf '%s!! %s %s\n' "$c_yel" "$c_off" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '%sxx %s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *) die "Unsupported OS: $(uname -s)" ;;
  esac
  if [[ $OS == linux ]]; then
    if   has apt-get; then PM=apt
    elif has dnf;     then PM=dnf
    elif has pacman;  then PM=pacman
    else die "Unsupported Linux distro (need apt, dnf or pacman)"; fi
  fi
  log "Platform: $OS${PM:+ ($PM)}"
}

start_sudo() {
  log "Requesting sudo (needed for system packages and Homebrew)"
  sudo -v || die "sudo is required"
  ( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit 0; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
}

# git_clone_or_update <url> <dest> [depth]
git_clone_or_update() {
  local url=$1 dest=$2 depth=${3:-}
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" pull --ff-only --quiet || warn "Could not update $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  git clone ${depth:+--depth="$depth"} "$url" "$dest" || { warn "Clone failed: $url"; return 1; }
}

# link_file <source> <target>: symlink, backing up anything already there
link_file() {
  local src=$1 dst=$2
  if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then return 0; fi
  if [[ -e "$dst" || -L "$dst" ]]; then
    log "Backing up $dst -> $dst.bak.$STAMP"
    mv "$dst" "$dst.bak.$STAMP"
  fi
  ln -s "$src" "$dst" && log "Linked $dst -> $src"
}

# ----------------------------------------------------------------------------
# System prerequisites (Linux only; on macOS Homebrew installs the CLT itself)
# ----------------------------------------------------------------------------
install_linux_prereqs() {
  [[ $OS == linux ]] || return 0
  log "Installing system prerequisites via $PM"
  case $PM in
    apt)
      sudo apt-get update -y
      sudo apt-get install -y build-essential procps curl file git unzip zsh \
        xdg-utils fontconfig python3-venv python3-pip ;;
    dnf)
      sudo dnf install -y @development-tools procps-ng curl file git unzip zsh \
        xdg-utils fontconfig libxcrypt-compat ;;
    pacman)
      sudo pacman -S --noconfirm --needed base-devel procps-ng curl file git unzip \
        zsh xdg-utils fontconfig ;;
  esac
}

# ----------------------------------------------------------------------------
# Homebrew
# ----------------------------------------------------------------------------
find_brew() {
  local p
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew \
           /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
    if [[ -x $p ]]; then echo "$p"; return 0; fi
  done
  command -v brew
}

persist_brew_env() {
  # macOS: ~/.zprofile (login shells). Linux: ~/.zshenv (terminals are often non-login).
  local file="$HOME/.zprofile"
  if [[ $OS == linux ]]; then file="$HOME/.zshenv"; fi
  if ! grep -qs 'shellenv' "$file"; then
    printf '\n# Homebrew\neval "$(%s shellenv)"\n' "$BREW_BIN" >> "$file"
    log "Added Homebrew to $file"
  fi
}

install_homebrew() {
  BREW_BIN="$(find_brew)"
  if [[ -z $BREW_BIN ]]; then
    log "Installing Homebrew"
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    BREW_BIN="$(find_brew)"
    [[ -n $BREW_BIN ]] || die "Homebrew installation failed"
  fi
  eval "$("$BREW_BIN" shellenv)"
  export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1
  persist_brew_env
  INSTALLED="$(brew list -1 2>/dev/null)"
}

brew_install() {
  local pkg
  for pkg in "$@"; do
    if grep -qxF "$pkg" <<<"$INSTALLED"; then continue; fi
    log "brew install $pkg"
    if brew install "$pkg"; then INSTALLED="$INSTALLED"$'\n'"$pkg"
    else warn "brew install failed: $pkg"; fi
  done
}

brew_cask_install() {
  local pkg
  for pkg in "$@"; do
    if grep -qxF "$pkg" <<<"$INSTALLED"; then continue; fi
    log "brew install --cask $pkg"
    if brew install --cask "$pkg"; then INSTALLED="$INSTALLED"$'\n'"$pkg"
    else warn "brew cask install failed: $pkg"; fi
  done
}

install_packages() {
  log "Installing packages with Homebrew"
  brew_install "${CORE_FORMULAE[@]}" "${LANG_FORMULAE[@]}" "${SHELL_FORMULAE[@]}"
  if [[ $OS == macos ]]; then brew_install "${MACOS_FORMULAE[@]}"; fi
  if [[ $OS == linux ]]; then brew_install "${LINUX_FORMULAE[@]}"; fi
  if [[ ${#EXTRA_FORMULAE[@]} -gt 0 ]]; then brew_install "${EXTRA_FORMULAE[@]}"; fi
}

# ----------------------------------------------------------------------------
# Rust (via rustup, the official way; do not also brew install rust)
# ----------------------------------------------------------------------------
install_rust() {
  if ! has rustup && [[ ! -x "$HOME/.cargo/bin/rustup" ]]; then
    log "Installing Rust via rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile default \
      || { warn "rustup install failed"; return 1; }
  fi
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"
  rustup component add rust-analyzer rust-src clippy rustfmt \
    || warn "Could not add some rustup components"
}

# ----------------------------------------------------------------------------
# Nerd Font (needed for eza icons and Powerlevel10k glyphs)
# ----------------------------------------------------------------------------
install_fonts() {
  log "Installing Meslo Nerd Font"
  if [[ $OS == macos ]]; then
    brew_cask_install font-meslo-lg-nerd-font
    return 0
  fi
  local dir="$HOME/.local/share/fonts/MesloLGS-NF" f
  local base="https://github.com/romkatv/powerlevel10k-media/raw/master"
  mkdir -p "$dir"
  for f in "MesloLGS NF Regular.ttf" "MesloLGS NF Bold.ttf" \
           "MesloLGS NF Italic.ttf" "MesloLGS NF Bold Italic.ttf"; do
    if [[ ! -f "$dir/$f" ]]; then
      curl -fsSL "$base/${f// /%20}" -o "$dir/$f" || warn "Font download failed: $f"
    fi
  done
  if has fc-cache; then fc-cache -f "$dir"; fi
}

# ----------------------------------------------------------------------------
# Zsh: Oh My Zsh, Powerlevel10k, plugins, and your zshrc
# ----------------------------------------------------------------------------
install_ohmyzsh() {
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
      "" --unattended || warn "Oh My Zsh install failed"
  fi
  local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  log "Installing Powerlevel10k and zsh plugins"
  git_clone_or_update https://github.com/romkatv/powerlevel10k.git \
    "$custom/themes/powerlevel10k" 1
  git_clone_or_update https://github.com/zsh-users/zsh-autosuggestions \
    "$custom/plugins/zsh-autosuggestions"
  git_clone_or_update https://github.com/zsh-users/zsh-syntax-highlighting \
    "$custom/plugins/zsh-syntax-highlighting"
}

setup_zsh_config() {
  local repo="$DOTFILES_DIR/ohmyzsh-config" c src=""
  log "Setting up your zsh config from $ZSH_REPO"
  git_clone_or_update "$ZSH_REPO" "$repo" || return 1

  for c in .zshrc zshrc zsh/.zshrc zsh/zshrc; do
    if [[ -f "$repo/$c" ]]; then src="$repo/$c"; break; fi
  done
  if [[ -z $src ]]; then
    warn "No .zshrc found in $repo - link it manually"
  else
    link_file "$src" "$HOME/.zshrc"
  fi

  for c in .p10k.zsh p10k.zsh zsh/.p10k.zsh; do
    if [[ -f "$repo/$c" ]]; then link_file "$repo/$c" "$HOME/.p10k.zsh"; break; fi
  done
}

set_default_shell() {
  local zsh_path current
  zsh_path="$(command -v zsh)"
  [[ -n $zsh_path ]] || { warn "zsh not found"; return 1; }
  current="${SHELL:-}"
  if [[ $current == *zsh ]]; then return 0; fi
  log "Changing login shell to $zsh_path"
  grep -qxF "$zsh_path" /etc/shells || echo "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  sudo chsh -s "$zsh_path" "$USER" || warn "chsh failed - run: chsh -s $zsh_path"
}

# ----------------------------------------------------------------------------
# Neovim / LazyVim
# ----------------------------------------------------------------------------
lua_table() {
  local out="" i
  for i in "$@"; do out+="\"$i\", "; done
  printf '%s' "$out"
}

setup_nvim_config() {
  local dest="$HOME/.config/nvim" origin=""
  log "Setting up your Neovim config from $NVIM_REPO"
  if [[ -d "$dest/.git" ]]; then origin="$(git -C "$dest" remote get-url origin 2>/dev/null)"; fi
  if [[ -n $origin && $origin == "$NVIM_REPO"* ]]; then
    git -C "$dest" pull --ff-only --quiet || warn "Could not update nvim config"
    return 0
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    log "Backing up existing $dest -> $dest.bak.$STAMP"
    mv "$dest" "$dest.bak.$STAMP"
  fi
  mkdir -p "$HOME/.config"
  git clone "$NVIM_REPO" "$dest" || { warn "Could not clone nvim config"; return 1; }
}

install_nvim_extras() {
  has nvim || { warn "nvim not found, skipping plugin install"; return 1; }
  [[ -f "$HOME/.config/nvim/init.lua" ]] || { warn "No nvim config, skipping plugin install"; return 1; }

  # Make sure cargo is on PATH for Mason packages that need it
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

  log "Installing Neovim plugins (lazy.nvim)"
  nvim --headless "+Lazy! sync" +qa 2>&1 || warn "Lazy sync reported a problem"
  echo

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/nvim-ts.XXXXXX")"
  cat > "$tmp" <<EOF
local langs = { $(lua_table "${TS_PARSERS[@]}") }
pcall(function() require("lazy").load({ plugins = { "nvim-treesitter" } }) end)
local ok, ts = pcall(require, "nvim-treesitter")
if not ok then return end
if pcall(require, "nvim-treesitter.configs") then
  -- master branch
  vim.cmd("silent! TSInstallSync " .. table.concat(langs, " "))
elseif type(ts.install) == "function" then
  -- main branch
  pcall(function() ts.install(langs):wait(600000) end)
end
EOF
  log "Installing treesitter parsers"
  nvim --headless "+luafile $tmp" +qa 2>&1; echo
  rm -f "$tmp"

  tmp="$(mktemp "${TMPDIR:-/tmp}/nvim-mason.XXXXXX")"
  cat > "$tmp" <<EOF
local packages = { $(lua_table "${MASON_PACKAGES[@]}") }
pcall(function() require("lazy").load({ plugins = { "mason.nvim" } }) end)
local ok, registry = pcall(require, "mason-registry")
if not ok then io.stdout:write("mason.nvim not available\n") return end

local pending, started = 0, false
registry.refresh(function()
  for _, name in ipairs(packages) do
    local okp, pkg = pcall(registry.get_package, name)
    if not okp then
      io.stdout:write("  unknown mason package: " .. name .. "\n")
    elseif not pkg:is_installed() then
      pending = pending + 1
      io.stdout:write("  installing " .. name .. "\n")
      pkg:install():once("closed", function()
        pending = pending - 1
        if not pkg:is_installed() then io.stdout:write("  FAILED: " .. name .. "\n") end
      end)
    end
  end
  started = true
end)
vim.wait(1200000, function() return started and pending == 0 end, 250)
EOF
  log "Installing LSP servers / formatters / debuggers via Mason (this takes a while)"
  nvim --headless "+luafile $tmp" +qa 2>&1; echo
  rm -f "$tmp"
}

# ----------------------------------------------------------------------------
# Firefox + default browser
# ----------------------------------------------------------------------------
setup_firefox() {
  log "Installing Firefox and setting it as the default browser"
  if [[ $OS == macos ]]; then
    brew_cask_install firefox
    brew_install defaultbrowser
    log "macOS will show a dialog - click \"Use Firefox\""
    defaultbrowser firefox || warn "Could not set default browser; do it in System Settings > Desktop & Dock"
    return 0
  fi

  case $PM in
    apt)    sudo apt-get install -y firefox || sudo apt-get install -y firefox-esr ;;
    dnf)    sudo dnf install -y firefox ;;
    pacman) sudo pacman -S --noconfirm --needed firefox ;;
  esac || warn "Firefox install failed"

  local d set=0
  for d in firefox.desktop firefox_firefox.desktop firefox-esr.desktop; do
    if [[ -e "/usr/share/applications/$d" || -e "/var/lib/snapd/desktop/applications/$d" ]]; then
      if xdg-settings set default-web-browser "$d" 2>/dev/null; then set=1; break; fi
    fi
  done
  [[ $set -eq 1 ]] || warn "Could not set Firefox as default; set it in your desktop's settings"
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  [[ $EUID -ne 0 ]] || die "Run as your normal user, not root (Homebrew refuses to run as root)"
  detect_platform
  start_sudo
  install_linux_prereqs
  install_homebrew
  install_packages
  install_rust
  install_fonts
  install_ohmyzsh
  setup_zsh_config
  setup_nvim_config
  install_nvim_extras
  setup_firefox
  set_default_shell

  echo
  log "Done."
  if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    printf '%sThings that need attention:%s\n' "$c_yel" "$c_off"
    local w; for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
  fi
  cat <<'NOTES'

Next steps:
  1. Set your terminal font to "MesloLGS Nerd Font" (Linux: "MesloLGS NF").
  2. Open a new terminal (or run: exec zsh). If you have no ~/.p10k.zsh, run: p10k configure
  3. Open nvim and run :checkhealth and :Mason to confirm everything installed.
NOTES
}

main "$@"