### 📁 Структура сайта:
```txt
/var/www/html/
├── index.html          # Главная страница
├── robots.txt
├── favicon.ico
├── about/
│   └── index.html
├── services/
│   └── index.html
└── contact/
    └── index.html
```

### 🚀 Как использовать:
```bash
curl -fsSL https://raw.githubusercontent.com/okhanuman22/deploy/main/install.sh | sudo -E bash
```
- или
```bash
wget https://gist.githubusercontent.com/okhanuman22/deploy/install.sh -O install.sh
chmod +x install.sh
sudo ./install.sh
```

### 👥 Управление пользователями:
```txt
user list    # Список клиентов
user qr      # QR-код основного пользователя
user add     # Добавить нового пользователя
user rm      # Удалить пользователя
user link    # Ссылка для выбранного пользователя
user help    # Справка
```
