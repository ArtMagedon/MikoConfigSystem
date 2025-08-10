#!/bin/bash

# Проверка git
if command -v git >/dev/null 2>&1; then
    echo "Git уже установлен."
else
    echo "Git не найден. Устанавливаю..."

    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y git
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y git
    elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -Sy git --noconfirm
    else
        echo "Неизвестный пакетный менеджер. Установи git вручную."
        exit 1
    fi
fi

# Проверяем SSH ключ
SSH_KEY="$HOME/.ssh/id_rsa.pub"
if [ -f "$SSH_KEY" ]; then
    echo "SSH ключ найден:"
else
    echo "SSH ключ не найден. Генерирую новый..."
    ssh-keygen -t rsa -b 4096 -C "$(git config --global user.email)" -f "$HOME/.ssh/id_rsa" -N ""
fi

echo ""
echo "Скопируйте этот публичный SSH ключ и добавьте его в настройки SSH-ключей вашего аккаунта GitHub:"
cat "$SSH_KEY"
echo ""

# Запуск ssh-agent и добавление ключа
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    echo "Запускаю ssh-agent..."
    eval "$(ssh-agent -s)"
fi

ssh-add "$HOME/.ssh/id_rsa" 2>/dev/null || echo "Не удалось добавить SSH ключ в ssh-agent"
