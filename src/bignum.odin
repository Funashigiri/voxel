package main

// Длинные целые числа для координат во вселенной — у вселенной нет края.
//
// Пока значение помещается в i64 (а это 9·10¹⁸ световых лет — на деле
// всегда), число хранится прямо в small и все операции идут без выделения
// памяти. Если число перерастает i64, оно продолжается кусками по 64 бита
// (mag) — сколько угодно длинное. Представление однозначное: всё, что
// помещается в i64, всегда хранится в small (от этого зависит хеш).
//
// Числа неизменяемы: операции возвращают новое значение; кусков mag
// выделяется только в «длинном» случае (по умолчанию во временной памяти —
// для хранения надолго нужен big_clone).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

Big :: struct {
	small: i64, // значение, если mag == nil
	mag:   []u64, // модуль кусками по 64 бита, младшие первыми
	neg:   bool, // знак для mag
}

big :: #force_inline proc "contextless" (v: i64) -> Big {
	return {small = v}
}

big_is_small :: #force_inline proc "contextless" (a: Big) -> bool {
	return a.mag == nil
}

big_clone :: proc(a: Big, allocator := context.allocator) -> Big {
	if a.mag == nil do return a
	return {mag = slice.clone(a.mag, allocator), neg = a.neg}
}

big_delete :: proc(a: Big, allocator := context.allocator) {
	if a.mag != nil do delete(a.mag, allocator)
}

// ---------------------------------------------------------------- модули

// Модуль числа и знак (small превращается во временный буфер на стеке вызывающего).
@(private = "file")
mag_of :: proc(a: Big, buf: ^[1]u64) -> (m: []u64, neg: bool) {
	if a.mag != nil do return a.mag, a.neg
	if a.small == 0 do return nil, false
	neg = a.small < 0
	buf[0] = neg ? u64(-(a.small + 1)) + 1 : u64(a.small) // |min i64| = 2^63 помещается в u64
	return buf[:], neg
}

@(private = "file")
mag_trim :: proc(m: []u64) -> []u64 {
	n := len(m)
	for n > 0 && m[n - 1] == 0 do n -= 1
	return m[:n]
}

@(private = "file")
mag_cmp :: proc(a, b: []u64) -> int {
	if len(a) != len(b) do return len(a) < len(b) ? -1 : 1
	#reverse for _, i in a {
		if a[i] != b[i] do return a[i] < b[i] ? -1 : 1
	}
	return 0
}

// Собирает число из модуля и знака; если помещается в i64 — в small.
@(private = "file")
from_mag :: proc(m: []u64, neg: bool, allocator: runtime.Allocator) -> Big {
	t := mag_trim(m)
	if len(t) == 0 do return {}
	if len(t) == 1 {
		v := t[0]
		if !neg && v <= u64(max(i64)) do return {small = i64(v)}
		if neg && v <= u64(1) << 63 do return {small = -i64(v - 1) - 1}
	}
	return {mag = slice.clone(t, allocator), neg = neg}
}

@(private = "file")
mag_add :: proc(a, b: []u64, allocator: runtime.Allocator) -> []u64 {
	n := max(len(a), len(b))
	out := make([]u64, n + 1, allocator)
	carry: u128
	for i in 0 ..< n {
		s := carry
		if i < len(a) do s += u128(a[i])
		if i < len(b) do s += u128(b[i])
		out[i] = u64(s)
		carry = s >> 64
	}
	out[n] = u64(carry)
	return out
}

// a - b, где |a| >= |b|.
@(private = "file")
mag_sub :: proc(a, b: []u64, allocator: runtime.Allocator) -> []u64 {
	out := make([]u64, len(a), allocator)
	borrow: u64
	for i in 0 ..< len(a) {
		bi: u64 = i < len(b) ? b[i] : 0
		d := a[i] - bi
		b1: u64 = a[i] < bi ? 1 : 0
		out[i] = d - borrow
		borrow = b1 | (d < borrow ? 1 : 0)
	}
	return out
}

// ---------------------------------------------------------------- операции

big_add :: proc(a, b: Big, allocator := context.temp_allocator) -> Big {
	if a.mag == nil && b.mag == nil {
		if s, overflow := intrinsics.overflow_add(a.small, b.small); !overflow do return {small = s}
	}
	ba, bb: [1]u64
	ma, na := mag_of(a, &ba)
	mb, nb := mag_of(b, &bb)
	if na == nb do return from_mag(mag_add(ma, mb, context.temp_allocator), na, allocator)
	switch mag_cmp(ma, mb) {
	case 0:
		return {}
	case 1:
		return from_mag(mag_sub(ma, mb, context.temp_allocator), na, allocator)
	case:
		return from_mag(mag_sub(mb, ma, context.temp_allocator), nb, allocator)
	}
}

big_neg :: proc(a: Big, allocator := context.temp_allocator) -> Big {
	if a.mag == nil {
		if a.small != min(i64) do return {small = -a.small}
		m := [1]u64{u64(1) << 63}
		return from_mag(m[:], false, allocator)
	}
	return from_mag(a.mag, !a.neg, allocator)
}

big_sub :: proc(a, b: Big, allocator := context.temp_allocator) -> Big {
	if a.mag == nil && b.mag == nil {
		if s, overflow := intrinsics.overflow_sub(a.small, b.small); !overflow do return {small = s}
	}
	return big_add(a, big_neg(b, context.temp_allocator), allocator)
}

big_add_i :: proc(a: Big, v: i64, allocator := context.temp_allocator) -> Big {
	return big_add(a, {small = v}, allocator)
}

big_mul_i :: proc(a: Big, v: i64, allocator := context.temp_allocator) -> Big {
	if a.mag == nil {
		if p, overflow := intrinsics.overflow_mul(a.small, v); !overflow do return {small = p}
	}
	if v == 0 do return {}
	ba: [1]u64
	ma, na := mag_of(a, &ba)
	if len(ma) == 0 do return {}
	mv := v < 0 ? u64(-(v + 1)) + 1 : u64(v)
	out := make([]u64, len(ma) + 1, context.temp_allocator)
	carry: u128
	for i in 0 ..< len(ma) {
		p := u128(ma[i]) * u128(mv) + carry
		out[i] = u64(p)
		carry = p >> 64
	}
	out[len(ma)] = u64(carry)
	return from_mag(out, na != (v < 0), allocator)
}

// Деление с округлением вниз (к минус бесконечности) на d > 0; остаток 0..d-1.
big_floor_div :: proc(a: Big, d: i64, allocator := context.temp_allocator) -> (q: Big, r: i64) {
	assert(d > 0)
	if a.mag == nil {
		qq := a.small / d
		rr := a.small % d
		if rr < 0 {
			qq -= 1
			rr += d
		}
		return {small = qq}, rr
	}
	out := make([]u64, len(a.mag), context.temp_allocator)
	rem: u128
	#reverse for _, i in a.mag {
		cur := rem << 64 | u128(a.mag[i])
		out[i] = u64(cur / u128(d))
		rem = cur % u128(d)
	}
	q = from_mag(out, a.neg, context.temp_allocator)
	r = i64(rem)
	if a.neg && r != 0 {
		q = big_add_i(q, -1, context.temp_allocator)
		r = d - r
	}
	return big_clone(q, allocator), r
}

big_cmp :: proc(a, b: Big) -> int {
	if a.mag == nil && b.mag == nil {
		return a.small < b.small ? -1 : a.small > b.small ? 1 : 0
	}
	// длинное число по модулю больше любого small
	if a.mag == nil do return b.neg ? 1 : -1
	if b.mag == nil do return a.neg ? -1 : 1
	if a.neg != b.neg do return a.neg ? -1 : 1
	c := mag_cmp(a.mag, b.mag)
	return a.neg ? -c : c
}

big_eq :: proc(a, b: Big) -> bool {
	return big_cmp(a, b) == 0
}

// Приближённое значение (для очень длинных — ±Inf).
big_to_f64 :: proc(a: Big) -> f64 {
	if a.mag == nil do return f64(a.small)
	v: f64
	#reverse for limb in a.mag do v = v * 18446744073709551616.0 + f64(limb)
	return a.neg ? -v : v
}

big_to_i64 :: proc(a: Big) -> (i64, bool) {
	if a.mag == nil do return a.small, true
	return 0, false
}

// Десятичный логарифм модуля (работает и для чисел длиннее, чем влезает в f64).
big_log10 :: proc(a: Big) -> f64 {
	if a.mag == nil do return a.small == 0 ? math.inf_f64(-1) : math.log10(abs(f64(a.small)))
	n := len(a.mag)
	top := f64(a.mag[n - 1])
	if n >= 2 do top += f64(a.mag[n - 2]) / 18446744073709551616.0
	return math.log10(top) + f64(n - 1) * 64 * math.log10(f64(2))
}

// Хеш числа (для генерации: одно и то же число — один и тот же хеш).
big_hash :: proc "contextless" (h: u64, a: Big) -> u64 {
	if a.mag == nil do return mix64(h ~ u64(a.small) * 0x9E3779B97F4A7C15)
	x := mix64(h ~ 0xB16B16 ~ u64(len(a.mag)) << 1 ~ (a.neg ? 1 : 0))
	for limb in a.mag do x = mix64(x ~ limb * 0xC2B2AE3D27D4EB4F)
	return x
}

// Перемешивание 64 бит (финализатор splitmix64).
mix64 :: proc "contextless" (v: u64) -> u64 {
	z := v + 0x9E3779B97F4A7C15
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// Точная десятичная запись.
big_string :: proc(a: Big, allocator := context.temp_allocator) -> string {
	if a.mag == nil do return fmt.aprintf("%d", a.small, allocator = allocator)
	// делим на 10^19, пока не кончится; куски собираем с конца
	BASE :: 10_000_000_000_000_000_000
	chunks := make([dynamic]u64, context.temp_allocator)
	cur := slice.clone(a.mag, context.temp_allocator)
	for len(cur) > 0 {
		rem: u128
		#reverse for _, i in cur {
			v := rem << 64 | u128(cur[i])
			cur[i] = u64(v / BASE)
			rem = v % BASE
		}
		append(&chunks, u64(rem))
		cur = mag_trim(cur)
	}
	b := strings.builder_make(allocator)
	if a.neg do strings.write_byte(&b, '-')
	#reverse for c, i in chunks {
		if i == len(chunks) - 1 {
			fmt.sbprintf(&b, "%d", c)
		} else {
			fmt.sbprintf(&b, "%019d", c)
		}
	}
	return strings.to_string(b)
}
