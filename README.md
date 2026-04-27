# WP-Bulk-Permalink-Flush

Bulk flush WordPress permalinks ทุกเว็บไซต์บน cPanel server ในครั้งเดียว

ใช้วิธี `wp eval` + `$GLOBALS["is_apache"] = true` + `flush_rewrite_rules(true)`  
เพื่อบังคับ write `.htaccess` บน LiteSpeed ได้ถูกต้อง

---

## รันเลย
**รัน Bulk (ทั้ง server / เลือก cPanel):**
```bash
bash <(curl -sL https://raw.githubusercontent.com/AnonymousVS/WP-Bulk-Permalink-Flush/main/wp-bulk-permalink-flush.sh)
```

---

## ไฟล์

| ไฟล์ | หน้าที่ |
|---|---|
| `wp-bulk-permalink-flush.sh` | รัน bulk flush ทั้ง server หรือเลือก cPanel |
| `wp-permalink-flush-test.sh` | ทดสอบ manual ทีละ 1 domain |

---

## ความต้องการ

- AlmaLinux 9 + cPanel/WHM
- LiteSpeed Enterprise
- WP-CLI (`/usr/local/bin/wp`)
- PHP CLI (`ea-php` จาก WHM)
- รันด้วย `root`

---

## ติดตั้ง

```bash
cp wp-bulk-permalink-flush.sh /usr/local/sbin/
cp wp-permalink-flush-test.sh /usr/local/sbin/
chmod +x /usr/local/sbin/wp-bulk-permalink-flush.sh
chmod +x /usr/local/sbin/wp-permalink-flush-test.sh
```

---

## วิธีใช้

### ทดสอบก่อน — 1 domain

```bash
bash /usr/local/sbin/wp-permalink-flush-test.sh apple999.co
```

ผลลัพธ์แสดง PASS/FAIL พร้อมตรวจ 3 เงื่อนไข:

- Flush command ได้รับ `done`
- `permalink_structure` = `/%postname%/`
- `.htaccess` มี `RewriteEngine On`

---

### รัน Bulk

```bash
bash /usr/local/sbin/wp-bulk-permalink-flush.sh
```

เลือกโหมด:

```
1. รัน Flush Permalink ทุกเว็บไซต์ใน server นี้ทั้งหมด
2. เลือกรันเฉพาะบาง cPanel ในเซิร์ฟเวอร์นี้
```

**Mode 1** — แสดง list cPanel ทั้งหมด → ยืนยัน y/N → รัน

**Mode 2** — แสดง list พร้อมหมายเลข → เลือก multiple ได้ (space หรือ comma) → ยืนยัน y/N → รัน

---

## โครงสร้าง path ที่รองรับ

```
/home/USERNAME/public_html/DOMAIN/   ← แบบที่ 1
/home/USERNAME/DOMAIN/               ← แบบที่ 2
```

---

## Domain ที่รองรับ

| ประเภท | การทำงาน |
|---|---|
| Addon domain | flush ปกติ |
| Parked / Alias domain | ใช้ path ของ parent + `--url=alias-domain.com` |

อ่าน domain จาก `/etc/userdomains` กรองออก:
- `.cp:` / `nobody` / `*`
- Main domain (จาก `/etc/trueuserdomains`)
- cPanel internal subdomain (`*.mainDomain`)

ตรวจ Parked/Alias จาก `/etc/userdatadomains`

---

## Log

บันทึกที่ `/usr/local/sbin/wp-bulk-permalink-flush.log`  
**เขียนทับทุกครั้งที่รัน** (ไม่ append) ป้องกัน log บวม

---

## วิธี flush ที่ใช้

```php
global $wp_rewrite;
$wp_rewrite->set_permalink_structure("/%postname%/");
$GLOBALS["is_apache"] = true;
flush_rewrite_rules(true);
echo "done";
```

LiteSpeed บน cPanel รองรับ `.htaccess` เหมือน Apache  
แต่ WordPress detect server string เห็น `LiteSpeed` → `is_apache = false` → ไม่ write `.htaccess`  
การ set `is_apache = true` ชั่วคราวใน eval บังคับให้ write `.htaccess` ได้ถูกต้อง  
ค่านี้หายไปเองเมื่อ eval จบ — ไม่มีผลถาวร
