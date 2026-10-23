# Shared ViciDial/HulkPhone/portal config, included by the :80 vhost (vicidial.conf) and :443 vhost (ssl.conf)
    DocumentRoot /var/www/html/campaignvoiceservices

    <Directory /var/www/html/campaignvoiceservices>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /vicidial /var/www/html/vicidial
    <Directory /var/www/html/vicidial>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /agc /var/www/html/agc
    <Directory /var/www/html/agc>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    Alias /hulkphone /var/www/html/hulkphone
    <Directory /var/www/html/hulkphone>
        Options FollowSymLinks
        Header always set Referrer-Policy "no-referrer"
        AllowOverride All
        Require all granted
    </Directory>
    Alias /crm /var/www/html/crm
    <Directory /var/www/html/crm>
        Options -Indexes
        AllowOverride All
        Require all granted
    </Directory>

    Alias /portal /var/www/html/dynportal
    <Directory /var/www/html/dynportal>
        Options -Indexes
        AllowOverride None
        Require all granted
        DirectoryIndex valid8.php
    </Directory>
    <Directory /var/www/html/dynportal/inc>
        Require all denied
    </Directory>

