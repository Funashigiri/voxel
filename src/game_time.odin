package main

// Игровое время.
// 1 стандартный час = 100 реальных секунд (земные сутки были бы 40 минут).
// Сутки планеты длятся столько стандартных часов, сколько выпало при генерации.
// На экране — местное время: сутки делятся на 24 местных часа, полдень всегда 12:00.
// Биология (заживление и т.п.) считается в стандартных часах.

import "core:math"

REAL_SECONDS_PER_STD_HOUR :: 100.0

Game_Clock :: struct {
	day_hours: f64, // длина местных суток в стандартных часах
	days:      f64, // местных суток с начала отсчёта (дробная часть — время суток)
	std_hours: f64, // стандартных часов прошло с появления в мире
}

clock_init :: proc(day_hours: f64, start_local_hour: f64) -> Game_Clock {
	return {day_hours = day_hours, days = start_local_hour / 24}
}

clock_tick :: proc(c: ^Game_Clock) {
	dh := TICK_DT / REAL_SECONDS_PER_STD_HOUR
	c.std_hours += dh
	c.days += dh / c.day_hours
}

// Номер дня (с 1) и местное время.
clock_local :: proc(c: ^Game_Clock) -> (day: int, hour, minute: int) {
	whole := math.floor(c.days)
	frac := c.days - whole
	minutes := int(frac * 24 * 60)
	return int(whole) + 1, minutes / 60, minutes % 60
}

// Длина местных суток в реальных минутах.
clock_day_real_minutes :: proc(c: ^Game_Clock) -> f64 {
	return c.day_hours * REAL_SECONDS_PER_STD_HOUR / 60
}
