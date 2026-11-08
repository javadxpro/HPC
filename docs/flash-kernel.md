# راهنمای فلش کرنل HPC روی گوشی (کپی‌پیست، با امنیت A/B)

گوشی: POCO X3 Pro (vayu/sm8150) — Droidian — روت‌شده — سیستم A/B

**کرنل‌ها:** `4.14.355 LTS` (پیش‌فرض) یا `4.14.190` (پایهٔ کنونی)

## چرا این روش امن است

- کرنل جدید فقط روی **اسلات دیگر** نوشته می‌شود؛ اسلات کنونی (کرنل سالم) دست‌نخورده می‌ماند.
- اسلات جدید با «حالت امتحان» (tries=5) فعال می‌شود؛ اگر کرنل جدید بوت نشود، ABL **خودکار** بعد از چند تلاش به اسلات سالم برمی‌گردد.
- پیش از هرچیز یک بکاپ کامل از boot کنونی در `/sdcard` گرفته می‌شود.

---

## ۱) در Termux این بلوک کامل را کپی و اجرا کن

```bash
# ==== اگر کرنل 190 می‌خواهی فقط همین خط را عوض کن ====
KERNEL_URL="https://raw.githubusercontent.com/javadxpro/HPC/arena/37022f35-hpc/artifacts/kernel-4.14.355/Image"
# برای 190:
# KERNEL_URL="https://raw.githubusercontent.com/javadxpro/HPC/arena/37022f35-hpc/artifacts/kernel-4.14.190-vayu/Image"

set -e
pkg install -y python wget

SLOT=$(getprop ro.boot_slot 2>/dev/null || true)
[ -z "$SLOT" ] && SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null | tr -d '_' || true)
[ -z "$SLOT" ] && SLOT=$(cat /proc/cmdline 2>/dev/null | grep -oE 'slot_suffix=._' | cut -d= -f2 || true)
if [ "$SLOT" != "a" ] && [ "$SLOT" != "b" ]; then
    echo "خطا: اسلات فعلی تشخیص داده نشد ('$SLOT')"; exit 1
fi
OTHER=$([ "$SLOT" = "a" ] && echo b || echo a)
OTHERNUM=$([ "$OTHER" = "a" ] && echo 0 || echo 1)
BOOT=/dev/block/bootdevice/by-name
WORK=/sdcard

echo "اسلات کنونی: $SLOT  ->  نصب کرنل جدید روی: $OTHER"

# 1) بکاپ boot کنونی
su -c "dd if=$BOOT/boot_$SLOT of=$WORK/boot_backup_$SLOT.img bs=4M"
echo "بکاپ آماده: $WORK/boot_backup_$SLOT.img"

# 2) دانلود ابزار repack و کرنل جدید
wget -O $WORK/repack-boot.py "https://raw.githubusercontent.com/javadxpro/HPC/arena/37022f35-hpc/tools/repack-boot.py"
wget -O $WORK/Image.new "$KERNEL_URL"

# 3) ساخت boot جدید (فقط کرنل عوض می‌شود؛ با خودبررسی)
python3 $WORK/repack-boot.py $WORK/boot_backup_$SLOT.img $WORK/Image.new $WORK/boot_new.img

# 4) نوشتن روی اسلات دیگر
su -c "dd if=$WORK/boot_new.img of=$BOOT/boot_$OTHER bs=4M"

# 5) آماده‌سازی اسلات جدید: حالت «امتحان» (برگشت خودکار فعال)
su -c "markboot --clear-successful boot_$OTHER"
su -c "markboot --set-tries boot_$OTHER 5"

# 6) فعال‌کردن اسلات جدید برای بوت بعدی (با شناسایی ابزار گوشی)
if su -c "markboot --help" 2>&1 | grep -q "set-active-boot"; then
    su -c "markboot --set-active-boot boot_$OTHER"
elif su -c "command -v bootctl" >/dev/null 2>&1; then
    su -c "bootctl set-active-boot-slot $OTHERNUM"
else
    echo "خطا: ابزار مناسب برای تغییر اسلات بوت پیدا نشد (markboot --set-active-boot / bootctl). ادامه نده!"
    exit 1
fi

# 7) وضعیت نهایی را ببین
su -c "markboot --dump" 2>/dev/null || su -c "markboot --dump boot_$OTHER" 2>/dev/null || true

echo "=== تموم شد! با 'su -c reboot' ری‌استارت کن ==="
```

بعد از اتمام:

```bash
su -c reboot
```

---

## ۲) بعد از بوت موفق (مهم، فقط یک‌بار)

وقتی گوشی با کرنل جدید بالا اومد و همه‌چیز سالم بود، این یک خط را اجرا کن تا اسلات جدید «تأییدشده» ثبت شود (وگرنه بعد از چند ری‌استارت برمی‌گردد):

```bash
su -c "markboot --set-successful boot_$(getprop ro.boot_slot)"
uname -r     # باید 4.14.355 (یا 190) نشان دهد
```

---

## ۳) اگر گوشی بوت نشد

- **حالت نرمال:** ABL بعد از چند تلاش ناموفق خودکار به اسلات قبلی (کرنل سالم) برمی‌گردد. صبر کن یا یک‌بار دکمهٔ پاور را نگه‌داشتن بده.
- **بازگردانی دستی** (فقط اگر خودکار انجام نشد؛ فرض می‌کنید اسلات کنونی قبل فلش a بود):

```bash
su -c "dd if=/sdcard/boot_backup_a.img of=/dev/block/bootdevice/by-name/boot_b bs=4M"
su -c "markboot --set-active-boot boot_a" 2>/dev/null || su -c "bootctl set-active-boot-slot 0"
su -c "markboot --set-successful boot_a"
su -c reboot
```

- **پاک‌سازی فایل‌های کاری** (بعد از موفقیت):

```bash
rm /sdcard/boot_new.img /sdcard/Image.new /sdcard/repack-boot.py
```

---

## نکات

- اگر در مرحلهٔ ۳ (repack) پیام `ERROR` دیدی، **ادامه نده** و خروجی را بفرست؛ اسکریپت در این حالت چیزی روی گوشی نوشته نیست.
- بکاپ (`boot_backup_*.img`) را تا وقتی مطمئن شدی کرنل جدید سالم است، پاک نکن.
- اسلات کنونی را با `getprop ro.boot_slot` می‌توانی هر وقت چک کنی.
