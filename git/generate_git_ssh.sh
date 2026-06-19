#!/usr/bin/env bash
set -e

SSH_DIR="$HOME/.ssh"
KEY_PATH="$SSH_DIR/git"
PUB_KEY_PATH="$SSH_DIR/git.pub"

echo "Используется домашняя директория: $HOME"

# Создаем .ssh если нет
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR" 2>/dev/null || true

# Проверяем наличие ssh-keygen
if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "Ошибка: ssh-keygen не найден. Установите OpenSSH."
    exit 1
fi

# Генерация ключа если его нет
if [ -f "$KEY_PATH" ]; then
    echo "Ключ уже существует: $KEY_PATH"
else
    echo "Генерация ключа ed25519..."
    ssh-keygen -t ed25519 -C "git-key" -f "$KEY_PATH" -N ""
fi

# Права (на Windows не критично)
chmod 600 "$KEY_PATH" 2>/dev/null || true

# Добавляем конфигурацию для GitHub если нужно
CONFIG_FILE="$SSH_DIR/config"

if [ ! -f "$CONFIG_FILE" ]; then
cat > "$CONFIG_FILE" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/git
    IdentitiesOnly yes
EOF
chmod 600 "$CONFIG_FILE" 2>/dev/null || true
else
    if ! grep -q "IdentityFile ~/.ssh/git" "$CONFIG_FILE"; then
cat >> "$CONFIG_FILE" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/git
    IdentitiesOnly yes
EOF
    fi
fi

echo ""
echo "===== ПУБЛИЧНЫЙ КЛЮЧ (добавить в GitHub) ====="
cat "$PUB_KEY_PATH"
echo "============================================="
echo ""
echo "Теперь добавьте этот ключ в GitHub:"
echo "Settings → SSH and GPG keys → New SSH key"