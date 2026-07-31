require "sdl"

SDL::Log.open("/tmp/sdl_feed_the_fish.log")

WIDTH  = 960
HEIGHT = 650

# Isometric floor grid: WORLD_COLS x WORLD_ROWS tiles, each TILE_W x TILE_H
# screen pixels at its widest/tallest point. Fish and food live at
# continuous (wx, wy) world coordinates over this grid, projected to screen
# space with the standard 2:1 isometric transform.
WORLD_COLS = 10
WORLD_ROWS = 10
TILE_W     = 64
TILE_H     = 36
ORIGIN_Y   = 150

FISH_COUNT   = 6
FISH_SPEED   = 2.6 # world tiles / second, chasing food
WANDER_SPEED = 1.1 # world tiles / second, idle wandering
EAT_RADIUS   = 0.35
EAT_DURATION = 450.0 # ms the fish pauses to "eat"

WATER_BG  = [12, 54, 94, 255]
SAND_A    = [222, 192, 140, 255]
SAND_B    = [200, 170, 116, 255]
GRID_LINE = [150, 120, 80, 255]

FISH_PALETTE = [
  [255, 140, 0, 255],
  [235, 90, 90, 255],
  [255, 210, 40, 255],
  [90, 210, 255, 255],
  [190, 130, 255, 255],
  [110, 235, 150, 255],
]

FOOD_COLORS = [
  [214, 178, 90, 255],
  [196, 158, 72, 255],
  [230, 200, 120, 255],
]

def iso_to_screen(wx, wy, origin_x, origin_y)
  sx = origin_x + (wx - wy) * (TILE_W / 2.0)
  sy = origin_y + (wx + wy) * (TILE_H / 2.0)
  [sx, sy]
end

def screen_to_iso(sx, sy, origin_x, origin_y)
  dx = (sx - origin_x).to_f
  dy = (sy - origin_y).to_f
  a  = dx / (TILE_W / 2.0)
  b  = dy / (TILE_H / 2.0)
  wx = (a + b) / 2.0
  wy = (b - a) / 2.0
  [wx, wy]
end

def clampf(v, lo, hi)
  if v < lo
    lo
  elsif v > hi
    hi
  else
    v
  end
end

def shade(color, factor)
  r = (color[0] * factor).round
  g = (color[1] * factor).round
  b = (color[2] * factor).round
  r = 255 if r > 255
  g = 255 if g > 255
  b = 255 if b > 255
  r = 0 if r < 0
  g = 0 if g < 0
  b = 0 if b < 0
  [r, g, b, color[3]]
end

# ---- Low-level scanline fills (only fill_rect/draw_line are available) ----

# Vertical taper: at y1 the half-width is hw1, at y2 it's hw2, straight
# line between. Two calls of this build a diamond; one call builds a fin.
def fill_tapered(renderer, cx, y1, hw1, y2, hw2, r, g, b, a)
  renderer.draw_color(r, g, b, a)
  lo = y1 < y2 ? y1 : y2
  hi = y1 < y2 ? y2 : y1
  span = y2 - y1
  span = 1 if span == 0
  y = lo
  while y <= hi
    t  = (y - y1).to_f / span
    hw = hw1 + (hw2 - hw1) * t
    w  = (hw * 2).round
    w  = 1 if w < 1
    renderer.fill_rect((cx - hw).round, y, w, 1)
    y += 1
  end
end

# Horizontal taper: at x1 the half-height is hh1, at x2 it's hh2. Used for
# the fish tail, which extends backward along x rather than up/down.
def fill_tapered_h(renderer, cy, x1, hh1, x2, hh2, r, g, b, a)
  renderer.draw_color(r, g, b, a)
  lo = x1 < x2 ? x1 : x2
  hi = x1 < x2 ? x2 : x1
  span = x2 - x1
  span = 1 if span == 0
  x = lo
  while x <= hi
    t  = (x - x1).to_f / span
    hh = hh1 + (hh2 - hh1) * t
    h  = (hh * 2).round
    h  = 1 if h < 1
    renderer.fill_rect(x, (cy - hh).round, 1, h)
    x += 1
  end
end

def fill_diamond(renderer, cx, cy, half_w, half_h, r, g, b, a)
  fill_tapered(renderer, cx, cy - half_h, 0, cy, half_w, r, g, b, a)
  fill_tapered(renderer, cx, cy, half_w, cy + half_h, 0, r, g, b, a)
end

def fill_ellipse(renderer, cx, cy, half_w, half_h, r, g, b, a)
  renderer.draw_color(r, g, b, a)
  dy = -half_h
  while dy <= half_h
    frac   = dy.to_f / half_h
    inside = 1.0 - frac * frac
    inside = 0.0 if inside < 0.0
    hw = half_w * Math.sqrt(inside)
    w  = (hw * 2).round
    renderer.fill_rect((cx - hw).round, cy + dy, w, 1) if w >= 1
    dy += 1
  end
end

# ---- World setup ----

def spawn_fish(i)
  {
    wx:           1.5 + rand * (WORLD_COLS - 3.0),
    wy:           1.5 + rand * (WORLD_ROWS - 3.0),
    facing:       1,
    phase:        rand * 6.28,
    state:        :wander,
    target_id:    -1,
    eat_timer:    0.0,
    wander_wx:    1.0,
    wander_wy:    1.0,
    wander_timer: 0.0,
    color:        FISH_PALETTE[i % FISH_PALETTE.length],
    eaten_count:  0,
  }
end

def new_world
  fish = []
  i = 0
  while i < FISH_COUNT
    fish.push(spawn_fish(i))
    i += 1
  end
  { fish: fish, foods: [], bubbles: [], next_food_id: 0 }
end

def spawn_food_cluster(world, cx, cy)
  count = 6 + rand(5)
  i = 0
  while i < count
    fx = clampf(cx + (rand - 0.5) * 0.9, 0.2, WORLD_COLS - 0.2)
    fy = clampf(cy + (rand - 0.5) * 0.9, 0.2, WORLD_ROWS - 0.2)
    food = {
      id:    world[:next_food_id],
      wx:    fx,
      wy:    fy,
      fall:  40.0 + rand(60).to_f,
      eaten: false,
      color: FOOD_COLORS[rand(FOOD_COLORS.length)],
    }
    world[:foods].push(food)
    world[:next_food_id] = world[:next_food_id] + 1
    i += 1
  end
end

def spawn_bubbles(world, fish)
  n = 3 + rand(3)
  i = 0
  while i < n
    bubble = {
      wx:   fish[:wx],
      wy:   fish[:wy],
      lift: 0.0,
      age:  0.0,
      life: 400.0 + rand(300).to_f,
      size: 2 + rand(3),
    }
    world[:bubbles].push(bubble)
    i += 1
  end
end

def find_food_by_id(foods, id)
  result = nil
  foods.each do |f|
    result = f if f[:id] == id
  end
  result
end

def nearest_uneaten_food(foods, wx, wy)
  best = nil
  best_dist = 0.0
  foods.each do |f|
    next if f[:eaten]
    dx = f[:wx] - wx
    dy = f[:wy] - wy
    d  = dx * dx + dy * dy
    if best == nil || d < best_dist
      best = f
      best_dist = d
    end
  end
  best
end

# ---- Updates ----

def update_food(world, dt)
  world[:foods].each do |f|
    if f[:fall] > 0.0
      f[:fall] = f[:fall] - dt * 0.08
      f[:fall] = 0.0 if f[:fall] < 0.0
    end
  end
  world[:foods] = world[:foods].select { |f| !f[:eaten] }
end

def update_bubbles(world, dt)
  world[:bubbles].each do |b|
    b[:age]  = b[:age] + dt
    b[:lift] = b[:lift] + dt * 0.05
  end
  world[:bubbles] = world[:bubbles].select { |b| b[:age] < b[:life] }
end

def update_fish(fish, world, dt)
  if fish[:state] == :eating
    fish[:eat_timer] = fish[:eat_timer] - dt
    fish[:phase]     = fish[:phase] + dt * 0.02
    fish[:state] = :wander if fish[:eat_timer] <= 0.0
    return
  end

  food = nil
  if fish[:target_id] != -1
    food = find_food_by_id(world[:foods], fish[:target_id])
    food = nil if food != nil && food[:eaten]
  end

  if food == nil
    food = nearest_uneaten_food(world[:foods], fish[:wx], fish[:wy])
    fish[:target_id] = food == nil ? -1 : food[:id]
  end

  if food != nil
    tx = food[:wx]
    ty = food[:wy]
    speed = FISH_SPEED
  else
    fish[:wander_timer] = fish[:wander_timer] - dt
    dxw = fish[:wander_wx] - fish[:wx]
    dyw = fish[:wander_wy] - fish[:wy]
    distw = Math.sqrt(dxw * dxw + dyw * dyw)

    if fish[:wander_timer] <= 0.0 || distw < 0.25
      fish[:wander_wx]    = 0.6 + rand * (WORLD_COLS - 1.2)
      fish[:wander_wy]    = 0.6 + rand * (WORLD_ROWS - 1.2)
      fish[:wander_timer] = 1500.0 + rand(2000).to_f
    end

    tx = fish[:wander_wx]
    ty = fish[:wander_wy]
    speed = WANDER_SPEED
  end

  dx = tx - fish[:wx]
  dy = ty - fish[:wy]
  dist = Math.sqrt(dx * dx + dy * dy)

  if food != nil && dist <= EAT_RADIUS
    food[:eaten]      = true
    fish[:state]      = :eating
    fish[:eat_timer]  = EAT_DURATION
    fish[:target_id]  = -1
    fish[:eaten_count] = fish[:eaten_count] + 1
    spawn_bubbles(world, fish)
  elsif dist > 0.0001
    nx = dx / dist
    ny = dy / dist
    step = speed * (dt / 1000.0)
    step = dist if step > dist
    fish[:wx] = fish[:wx] + nx * step
    fish[:wy] = fish[:wy] + ny * step

    screen_dx = nx - ny
    fish[:facing] = screen_dx >= 0.0 ? 1 : -1
    fish[:phase] = fish[:phase] + dt * (0.006 + speed * 0.002)
  end
end

# ---- Rendering ----

def draw_floor(renderer, origin_x, origin_y)
  row = 0
  while row < WORLD_ROWS
    col = 0
    while col < WORLD_COLS
      pos = iso_to_screen(col + 0.5, row + 0.5, origin_x, origin_y)
      color = (col + row) % 2 == 0 ? SAND_A : SAND_B
      fill_diamond(renderer, pos[0].round, pos[1].round, TILE_W / 2, TILE_H / 2,
                   color[0], color[1], color[2], color[3])
      col += 1
    end
    row += 1
  end

  renderer.draw_color(GRID_LINE[0], GRID_LINE[1], GRID_LINE[2], GRID_LINE[3])

  row = 0
  while row <= WORLD_ROWS
    p1 = iso_to_screen(0, row, origin_x, origin_y)
    p2 = iso_to_screen(WORLD_COLS, row, origin_x, origin_y)
    renderer.draw_line(p1[0].round, p1[1].round, p2[0].round, p2[1].round)
    row += 1
  end

  col = 0
  while col <= WORLD_COLS
    p1 = iso_to_screen(col, 0, origin_x, origin_y)
    p2 = iso_to_screen(col, WORLD_ROWS, origin_x, origin_y)
    renderer.draw_line(p1[0].round, p1[1].round, p2[0].round, p2[1].round)
    col += 1
  end
end

def draw_food(renderer, food, origin_x, origin_y)
  pos = iso_to_screen(food[:wx], food[:wy], origin_x, origin_y)
  sx = pos[0].round
  sy = (pos[1] - food[:fall]).round
  color = food[:color]
  renderer.draw_color(color[0], color[1], color[2], color[3])
  renderer.fill_rect(sx - 2, sy - 2, 4, 4)
end

def draw_bubble(renderer, bubble, origin_x, origin_y)
  pos = iso_to_screen(bubble[:wx], bubble[:wy], origin_x, origin_y)
  sx = pos[0].round
  sy = (pos[1] - 10.0 - bubble[:lift]).round
  s  = bubble[:size]
  renderer.draw_color(215, 238, 255, 255)
  renderer.fill_rect(sx - s / 2, sy - s / 2, s, s)
end

def draw_fish(renderer, fish, origin_x, origin_y)
  pos = iso_to_screen(fish[:wx], fish[:wy], origin_x, origin_y)
  sx = pos[0]
  sy = pos[1] - 10.0 + Math.sin(fish[:phase]) * 2.0

  facing = fish[:facing]
  color  = fish[:color]
  dark   = shade(color, 0.55)
  light  = shade(color, 1.2)
  wag    = Math.sin(fish[:phase] * 1.8) * 5.0

  tail_tip_x  = (sx - facing * 21.0).round
  tail_base_x = (sx - facing * 10.0).round
  tail_cy     = (sy + wag * 0.4).round
  fill_tapered_h(renderer, tail_cy, tail_tip_x, 2, tail_base_x, 7,
                 dark[0], dark[1], dark[2], dark[3])

  fill_ellipse(renderer, sx.round, sy.round, 11, 7, color[0], color[1], color[2], color[3])
  fill_ellipse(renderer, sx.round, (sy + 3).round, 7, 3, light[0], light[1], light[2], light[3])

  fin_top  = (sy - 11).round
  fin_base = (sy - 5).round
  fill_tapered(renderer, sx.round, fin_top, 0, fin_base, 4, dark[0], dark[1], dark[2], dark[3])

  mouth_r = fish[:state] == :eating ? 3 : 1
  mouth_x = (sx + facing * 11).round
  mouth_y = sy.round
  renderer.draw_color(30, 20, 20, 255)
  renderer.fill_rect(mouth_x - mouth_r, mouth_y - mouth_r, mouth_r * 2, mouth_r * 2)

  eye_x = (sx + facing * 5).round
  eye_y = (sy - 3).round
  renderer.draw_color(20, 20, 20, 255)
  renderer.fill_rect(eye_x - 1, eye_y - 1, 2, 2)
end

def build_depth_list(world)
  list = []
  world[:fish].each_with_index do |f, i|
    list.push({ kind: :fish, depth: f[:wx] + f[:wy], idx: i })
  end
  world[:foods].each_with_index do |f, i|
    list.push({ kind: :food, depth: f[:wx] + f[:wy] - 0.001, idx: i })
  end
  list.sort_by { |e| e[:depth] }
end

def draw_scoreboard(renderer, font, world)
  hud = SDL::Color::WHITE
  renderer.draw_text(font, "Score", 12, 64, hud[0], hud[1], hud[2], hud[3])

  y = 92
  world[:fish].each_with_index do |f, i|
    color = f[:color]
    renderer.draw_color(color[0], color[1], color[2], color[3])
    renderer.fill_rect(12, y, 16, 16)

    label = "Fish #{i + 1}: #{f[:eaten_count]}"
    renderer.draw_text(font, label, 36, y - 2, hud[0], hud[1], hud[2], hud[3])
    y = y + 26
  end
end

def render(renderer, font, world, origin_x, origin_y)
  bg = WATER_BG
  renderer.draw_color(bg[0], bg[1], bg[2], bg[3])
  renderer.clear

  draw_floor(renderer, origin_x, origin_y)

  build_depth_list(world).each do |e|
    if e[:kind] == :fish
      draw_fish(renderer, world[:fish][e[:idx]], origin_x, origin_y)
    else
      draw_food(renderer, world[:foods][e[:idx]], origin_x, origin_y)
    end
  end

  world[:bubbles].each { |b| draw_bubble(renderer, b, origin_x, origin_y) }

  hud = SDL::Color::WHITE
  renderer.draw_text(font, "Click to drop fish food", 12, 8, hud[0], hud[1], hud[2], hud[3])
  renderer.draw_text(font, "Esc to quit", 12, 32, hud[0], hud[1], hud[2], hud[3])

  draw_scoreboard(renderer, font, world)

  renderer.present
end

# ---- Main loop ----

SDL::Screen.open("Feed the Fish", width: WIDTH, height: HEIGHT) do |window, renderer|
  font      = SDL::Font.bundled(SDL::Fonts::VT323_NAME, 20)
  world     = new_world
  last_tick = SDL::Screen.ticks
  running   = true

  while running
    origin_x = window.width / 2
    origin_y = ORIGIN_Y

    while (event_type = SDL::Event.poll)
      if event_type == LibSDL::QUIT
        running = false
      elsif event_type == LibSDL::KEYDOWN
        running = false if SDL::Event.key_sym == LibSDL::K_ESCAPE
      elsif event_type == LibSDL::MOUSEBUTTONDOWN
        if SDL::Event.mouse_button == LibSDL::BUTTON_LEFT
          pos = screen_to_iso(SDL::Event.mouse_x, SDL::Event.mouse_y, origin_x, origin_y)
          spawn_food_cluster(world, pos[0], pos[1])
        end
      end
    end

    now = SDL::Screen.ticks
    dt  = (now - last_tick).to_f
    dt  = 50.0 if dt > 50.0
    last_tick = now

    update_food(world, dt)
    world[:fish].each { |f| update_fish(f, world, dt) }
    update_bubbles(world, dt)

    render(renderer, font, world, origin_x, origin_y)
    SDL::Screen.delay(16)
  end

  font.close
end
