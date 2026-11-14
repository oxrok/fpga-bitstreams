#!/usr/bin/env python3
# Generates docs/pins.svg, the Tang Nano 20K headers as this gateware uses
# them. Run from the oxla-tn20k directory after changing cst/.
left = [("73","ch","CH0",""),("74","ch","CH1",""),("75","trig","TRIG OUT","also a BL616 GPIO"),
        ("85","sh","CH14","SD card DAT1, 10 k pull-up"),
        ("77","ch","CH2",""),("15","led","LED","alive"),("16","led","LED","UART activity"),
        ("27","ch","CH3",""),("28","ch","CH4",""),("25","no","","HDMI CEC, 27 k pull-up"),
        ("26","no","","HDMI hot plug, 5.1 k pull-down"),
        ("29","ch","CH5",""),("30","ch","CH6",""),("31","ch","CH7",""),
        ("17","led","LED","running"),("20","led","LED","overflow"),("19","led","LED","done"),("18","led","LED","triggered"),
        ("3V3","pwr","3V3",""),("GND","gnd","GND","")]
right = [("5V","pwr","5V",""),("GND","gnd","GND",""),("76","sh","CH15","also a BL616 GPIO"),
         ("80","sh","CH13","SD card DAT2, 10 k pull-up"),
         ("42","ch2","CH8","ADC CLK in the ADC build"),("41","ch2","CH9",""),("56","no","","I2S BCLK"),("54","no","","I2S DIN"),
         ("51","no","","audio amplifier enable"),("48","ch2","CH10",""),("55","no","","I2S LRCK"),
         ("49","no","","backlight enable, 27 k pull-up"),
         ("86","no","","BL616 GPIO, held high"),("79","no","","WS2812 LED"),("GND","gnd","GND",""),("3V3","pwr","3V3",""),
         ("72","ch2","CH11",""),("71","ch2","CH12",""),("53","no","","HDMI DDC clock"),("52","no","","HDMI DDC data")]
fill = {"ch":("#2563eb","#fff"),"ch2":("#7c3aed","#fff"),"sh":("#c4b5fd","#2e1065"),"trig":("#d97706","#fff"),"adc":("#0d9488","#fff"),
        "pwr":("#dc2626","#fff"),"gnd":("#1f2937","#fff"),"led":("#fde68a","#422006")}
W,H=940,740
y0,pitch=120,27
bx,bw=390,160
o=[]
o.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="-apple-system, \'Segoe UI\', Helvetica, Arial, sans-serif" role="img" aria-labelledby="t d">')
o.append('<title id="t">Tang Nano 20K header pins as the oxrok logic analyzer uses them</title>')
o.append('<desc id="d">Top view, USB connector up. Left header, top to bottom: CH0 73, CH1 74, trigger out 75, CH14 85, CH2 77, LEDs 15 and 16, CH3 27, CH4 28, 25 and 26 unused, CH5 29, CH6 30, CH7 31, LEDs 17, 20, 19, 18, 3V3, GND. Right header: 5V, GND, CH15 76, CH13 80, CH8 42, CH9 41, 56, 54 and 51 unused, CH10 48, 55, 49, 86 and 79 unused, GND, 3V3, CH11 72, CH12 71, 53 and 52 unused.</desc>')
o.append(f'<rect width="{W}" height="{H}" rx="12" fill="#f8fafc" stroke="#e2e8f0"/>')
o.append(f'<text x="{W/2}" y="34" text-anchor="middle" font-size="17" font-weight="600" fill="#0f172a">Tang Nano 20K: logic analyzer pins</text>')
o.append(f'<text x="{W/2}" y="54" text-anchor="middle" font-size="12" fill="#64748b">top view, USB-C up; numbers are the labels printed on the board (FPGA pins); 3.3 V only</text>')
# board
by=y0-30; bh=pitch*19+60
o.append(f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="14" fill="#0b1220"/>')
o.append(f'<rect x="{bx+50}" y="{by-14}" width="60" height="44" rx="6" fill="#cbd5e1" stroke="#94a3b8"/>')
o.append(f'<text x="{bx+bw/2}" y="{by+13}" text-anchor="middle" font-size="10" fill="#334155">USB-C</text>')
o.append(f'<rect x="{bx+45}" y="{by+110}" width="70" height="70" rx="4" fill="#1e293b" stroke="#334155"/>')
o.append(f'<text x="{bx+bw/2}" y="{by+142}" text-anchor="middle" font-size="10" fill="#94a3b8">GW2AR-18</text>')
o.append(f'<text x="{bx+bw/2}" y="{by+156}" text-anchor="middle" font-size="9" fill="#64748b">+ SDRAM</text>')
o.append(f'<rect x="{bx+48}" y="{by+bh-52}" width="64" height="62" rx="5" fill="#cbd5e1" stroke="#94a3b8"/>')
o.append(f'<text x="{bx+bw/2}" y="{by+bh-18}" text-anchor="middle" font-size="10" fill="#334155">HDMI</text>')
o.append(f'<text x="{bx+bw/2}" y="{by+330}" text-anchor="middle" font-size="11" fill="#475569" letter-spacing="2" transform="rotate(90 {bx+bw/2} {by+330})">TANG NANO 20K</text>')
def row(i, ent, side):
    num,kind,role,note=ent
    y=y0+i*pitch
    px = bx+14 if side=="L" else bx+bw-14
    d = -1 if side=="L" else 1
    o.append(f'<circle cx="{px}" cy="{y}" r="6.5" fill="#fbbf24" stroke="#92400e"/><circle cx="{px}" cy="{y}" r="2.5" fill="#0b1220"/>')
    edge = bx if side=="L" else bx+bw
    x1 = edge + d*8; x2 = edge + d*26
    o.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" stroke="#94a3b8"/>')
    # pin number
    nx = edge + d*46
    o.append(f'<text x="{nx}" y="{y+4}" text-anchor="middle" font-size="12" font-weight="600" fill="{"#0f172a" if kind!="no" else "#94a3b8"}">{num if kind not in ("pwr","gnd") else ""}</text>')
    cw=84
    cx = edge + d*66 if side=="R" else edge + d*66 - cw
    if kind=="no":
        o.append(f'<rect x="{cx}" y="{y-10}" width="{cw}" height="20" rx="4" fill="none" stroke="#cbd5e1" stroke-dasharray="3 3"/>')
        o.append(f'<text x="{cx+cw/2}" y="{y+4}" text-anchor="middle" font-size="11" fill="#94a3b8">not used</text>')
    else:
        f,t=fill[kind]
        o.append(f'<rect x="{cx}" y="{y-10}" width="{cw}" height="20" rx="4" fill="{f}"/>')
        o.append(f'<text x="{cx+cw/2}" y="{y+4}" text-anchor="middle" font-size="12" font-weight="600" fill="{t}">{role}</text>')
    if note:
        tx = cx - 10 if side=="L" else cx + cw + 10
        o.append(f'<text x="{tx}" y="{y+4}" text-anchor="{"end" if side=="L" else "start"}" font-size="11" fill="#64748b">{note}</text>')
for i,e in enumerate(left): row(i,e,"L")
for i,e in enumerate(right): row(i,e,"R")
# legend
ly=H-52
items=[("ch","CH0-CH7","every variant"),("ch2","CH8-CH12","16 channel variants"),("sh","CH13-CH15","the same, pin shared"),("trig","TRIG OUT","output"),("led","LED","status")]
x=40
for k,name,what in items:
    f,t=fill[k]
    o.append(f'<rect x="{x}" y="{ly}" width="78" height="20" rx="4" fill="{f}"/><text x="{x+39}" y="{ly+14}" text-anchor="middle" font-size="11" font-weight="600" fill="{t}">{name}</text>')
    o.append(f'<text x="{x+86}" y="{ly+14}" font-size="11" fill="#475569">{what}</text>')
    x += 86 + 6*len(what) + 18
o.append(f'<text x="40" y="{ly+40}" font-size="11" fill="#64748b">Inputs have the FPGA\'s weak pull-down. CH13-CH15 share their pin with something on the board; the pins marked "not used" are driven or loaded by it.</text>')
o.append('</svg>')
open('docs/pins.svg','w').write("\n".join(o)+"\n")
