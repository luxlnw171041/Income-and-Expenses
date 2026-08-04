# ตู้ซื่อสัตย์ — Honesty Shop PWA

แอปจัดการร้านค้าแบบ Self-Service ที่ตั้งตามชั้นตึกต่างๆ นับสต็อก บันทึกรายรับ-รายจ่าย
ทำงานแบบ Offline-First บนมือถือ ต่อกับ Supabase, deploy บน GitHub Pages ได้ทันที

## ต่อกับ Supabase จริง (3 ขั้นตอน)

**1. สร้างตาราง/ฟังก์ชัน/views ใน Supabase**
- เข้า Supabase Dashboard > โปรเจกต์ของคุณ > SQL Editor > New query
- คัดลอกทั้งหมดจากไฟล์ `supabase_setup.sql` ไปวางแล้วกด Run
- สคริปต์นี้จะสร้าง: 8 ตารางตามสเปก, stored procedure `process_stock_audit` (คำนวณของหายแบบ FIFO ตามต้นทุน), `add_transaction` (บันทึกรายรับ-จ่ายแบบ atomic), 3 views (`view_dashboard_overview`, `view_building_performance`, `view_low_stock_alerts`) และ RLS policies เริ่มต้น

**2. ใส่ค่า API keys**
- เปิดไฟล์ `index.html` หาบรรทัด:
  ```js
  const SUPABASE_URL = 'YOUR_SUPABASE_URL';
  const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
  ```
- แทนที่ด้วยค่าจริงจาก Supabase Dashboard > Project Settings > API
- แอปจะสลับจาก Mock Mode ไปใช้ Supabase จริงโดยอัตโนมัติ

**3. เพิ่มข้อมูลเริ่มต้น**
- เปิดแอป ไปที่แท็บ "จัดการ" เพื่อเพิ่มตึก, ชั้น, สินค้า และจัดวางสินค้าเข้าชั้น
- สำหรับต้นทุนสินค้า (`stock_batches`) แนะนำให้ insert ผ่าน Table Editor ใน Supabase โดยตรงในช่วงแรก (เผื่อเพิ่ม UI จัดการ batch ในเวอร์ชันถัดไป)

## Deploy บน GitHub Pages
1. สร้าง repo ใหม่ อัปโหลดไฟล์ทั้งหมดในโฟลเดอร์นี้ (`index.html`, `manifest.json`, `sw.js`) ไว้ที่ root
2. Settings > Pages > Source เลือก branch ที่อัปโหลดไว้ (เช่น `main`) และ folder `/root`
3. รอสักครู่ จะได้ลิงก์ `https://<username>.github.io/<repo>/`
4. เปิดลิงก์บนมือถือ แล้วเลือก "เพิ่มไปยังหน้าจอโฮม" (Add to Home Screen) เพื่อใช้งานแบบแอป

## ระบบ Offline Sync ทำงานอย่างไร
- ตอนนับสต็อกแล้วกด "บันทึกการนับสต็อก": ถ้ามีเน็ตจะยิงไป Supabase ทันที
- ถ้าไม่มีเน็ต จะบันทึกลง `localStorage` (key: `pending_stock_sync`) และแจ้งเตือน "บันทึกในเครื่องแล้ว"
- เมื่อเน็ตกลับมา (`window online` event) แอปจะไล่ส่งข้อมูลที่ค้างแบบ FIFO ทีละรายการไปที่ Supabase อัตโนมัติ พร้อม badge แสดงจำนวนที่รอซิงค์ที่มุมขวาบน

## โครงสร้างไฟล์
```
honesty-shop/
├── index.html          ← ตัวแอปทั้งหมด (UI + logic + offline sync)
├── manifest.json        ← PWA manifest (ติดตั้งเป็นแอปบนมือถือได้)
├── sw.js                 ← Service worker (cache หน้าแอปไว้ใช้ตอนออฟไลน์)
├── supabase_setup.sql    ← สคริปต์สร้างฐานข้อมูลทั้งหมด
└── README.md
```

## ดีไซน์ที่ใช้
- สีหลัก: เขียวป่าเข้ม `#145C52` (ความน่าเชื่อถือ) + ส้มอำพัน `#F2A33C` (accent/แจ้งเตือน)
- ฟอนต์: **Kanit** (หัวข้อ/ตัวเลข) + **Sarabun** (เนื้อหา อ่านภาษาไทยง่าย)
- หน้านับสต็อกออกแบบเป็น "ป้ายชั้นวางสินค้า" (เส้นประ + รอยเจาะ) ตอบโจทย์ธีมร้านค้าตามชั้นวางโดยตรง
- Animation: page transition, ปุ่มกดมี feedback, badge ตัวเลขเด้งเมื่อตัวเลขเปลี่ยน, toast แจ้งเตือนแบบเลื่อนเข้า, skeleton loading ระหว่างโหลดข้อมูล
