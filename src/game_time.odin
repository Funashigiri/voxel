package main

// Игровое время.
// 1 стандартный час = 100 реальных секунд (земные сутки были бы 40 минут).
// Часы считают стандартные часы с момента высадки; всё остальное — местное
// время, сутки, времена года — считается из положения планеты (astro.odin).
// Биология (заживление и т.п.) идёт в стандартных часах.

REAL_SECONDS_PER_STD_HOUR :: 100.0

Game_Clock :: struct {
	day_hours: f64, // длина местных суток в стандартных часах
	std_hours: f64, // стандартных часов прошло с высадки
	timescale: f64, // ускорение времени (отладка), обычно 1
}

clock_init :: proc(day_hours, timescale: f64) -> Game_Clock {
	return {day_hours = day_hours, timescale = timescale}
}

// Сколько стандартных часов проходит за тик.
clock_tick_hours :: proc(c: ^Game_Clock) -> f64 {
	return TICK_DT / REAL_SECONDS_PER_STD_HOUR * c.timescale
}

clock_tick :: proc(c: ^Game_Clock) {
	c.std_hours += clock_tick_hours(c)
}

// Длина местных суток в реальных минутах.
clock_day_real_minutes :: proc(c: ^Game_Clock) -> f64 {
	return c.day_hours * REAL_SECONDS_PER_STD_HOUR / 60
}
