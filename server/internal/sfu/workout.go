package sfu

// The trainer's timer: a workout the host (or a moderator) loads into the
// room and runs, step by step, for everyone. The clock is here, on the
// server, and every change is broadcast with the time left, so everyone
// counts down the same second whatever their phone's clock says.

import (
	"time"
	"unicode/utf8"

	"github.com/monqyClouds/Fitmeasure/server/internal/signal"
)

// Limits on a loaded workout.
const (
	maxWorkoutSteps   = 300
	maxStepSeconds    = 3600
	maxWorkoutText    = 80
	minBreakSeconds   = 10
	maxBreakSeconds   = 900
	defaultBreakLabel = "Water break"
)

// workout is a room's running workout. Guarded by room.wmu.
type workout struct {
	title string
	steps []signal.WorkoutStep
	index int

	running bool
	endsAt  time.Time     // while running a timed step
	left    time.Duration // while paused: time left in the current step

	// After a break, the step it interrupted carries on with the time it
	// had left.
	resumeIndex int
	resumeLeft  time.Duration

	timer *time.Timer
	gen   int // bumped on every change, so a stale timer does nothing
}

var workoutTypes = map[string]bool{
	signal.TypeWorkoutLoad:    true,
	signal.TypeWorkoutControl: true,
}

// handleWorkout carries out a workout message from p, if p may run the
// workout, and returns what to tell p if not ("" when done).
func (rm *room) handleWorkout(p *participant, msg signal.Message) string {
	if !rm.canModerate(p) {
		return "only the host and moderators can run the workout"
	}
	switch msg.Type {
	case signal.TypeWorkoutLoad:
		if msg.Workout == nil {
			return "workout_load needs a workout"
		}
		steps, problem := cleanSteps(msg.Workout.Steps)
		if problem != "" {
			return problem
		}
		rm.wmu.Lock()
		rm.stopTimerLocked()
		rm.workout = &workout{title: clip(msg.Workout.Title), steps: steps, resumeIndex: -1}
		rm.workout.left = stepLength(steps[0])
		rm.wmu.Unlock()

	case signal.TypeWorkoutControl:
		rm.wmu.Lock()
		w := rm.workout
		if w == nil {
			rm.wmu.Unlock()
			return "no workout is loaded"
		}
		now := time.Now()
		switch msg.Action {
		case signal.WorkoutStart:
			if w.index < len(w.steps) && !w.running {
				w.running = true
				w.endsAt = now.Add(w.left)
			}
		case signal.WorkoutPause:
			if w.running {
				w.left = w.remaining(now)
				w.running = false
			}
		case signal.WorkoutNext:
			w.enter(w.index+1, now)
		case signal.WorkoutPrev:
			if w.index > 0 {
				w.enter(w.index-1, now)
			} else {
				w.enter(0, now)
			}
		case signal.WorkoutBreak:
			secs := msg.Seconds
			if secs < minBreakSeconds || secs > maxBreakSeconds {
				rm.wmu.Unlock()
				return "a break is 10 seconds to 15 minutes"
			}
			w.addBreak(secs, now)
		case signal.WorkoutStop:
			rm.stopTimerLocked()
			rm.workout = nil
			rm.wmu.Unlock()
			rm.broadcastWorkout()
			return ""
		default:
			rm.wmu.Unlock()
			return "unknown workout action " + msg.Action
		}
		rm.wmu.Unlock()
	}
	rm.scheduleWorkout()
	rm.broadcastWorkout()
	return ""
}

// cleanSteps checks a loaded workout's steps and trims their text.
func cleanSteps(in []signal.WorkoutStep) ([]signal.WorkoutStep, string) {
	if len(in) == 0 {
		return nil, "a workout needs at least one step"
	}
	if len(in) > maxWorkoutSteps {
		return nil, "a workout has at most 300 steps"
	}
	out := make([]signal.WorkoutStep, len(in))
	for i, s := range in {
		switch s.Kind {
		case signal.StepWork:
		case signal.StepRest, signal.StepBreak:
			if s.Seconds <= 0 {
				return nil, "rest and breaks need a length"
			}
		default:
			return nil, "steps are work, rest or break"
		}
		if s.Seconds < 0 || s.Seconds > maxStepSeconds {
			return nil, "a step lasts at most an hour"
		}
		s.Title, s.Detail = clip(s.Title), clip(s.Detail)
		out[i] = s
	}
	return out, ""
}

func clip(s string) string {
	if utf8.RuneCountInString(s) <= maxWorkoutText {
		return s
	}
	return string([]rune(s)[:maxWorkoutText])
}

func stepLength(s signal.WorkoutStep) time.Duration {
	return time.Duration(s.Seconds) * time.Second
}

// remaining is the time left in the current step.
func (w *workout) remaining(now time.Time) time.Duration {
	if w.index >= len(w.steps) {
		return 0
	}
	if !w.running {
		return w.left
	}
	if w.steps[w.index].Seconds == 0 {
		return 0 // untimed: waits for the host
	}
	if d := w.endsAt.Sub(now); d > 0 {
		return d
	}
	return 0
}

// enter starts step i in full (or with what it had left, if a break
// interrupted it), keeping the workout running or paused.
func (w *workout) enter(i int, now time.Time) {
	if i > len(w.steps) {
		i = len(w.steps)
	}
	w.index = i
	if i >= len(w.steps) {
		w.running = false
		w.left = 0
		return
	}
	length := stepLength(w.steps[i])
	if i == w.resumeIndex && w.resumeLeft > 0 {
		length = w.resumeLeft
		w.resumeIndex, w.resumeLeft = -1, 0
	}
	w.left = length
	w.endsAt = now.Add(length)
}

// addBreak puts a break in before the rest of the current step, and starts
// it.
func (w *workout) addBreak(secs int, now time.Time) {
	brk := signal.WorkoutStep{Kind: signal.StepBreak, Title: defaultBreakLabel, Seconds: secs}
	if w.index >= len(w.steps) {
		w.steps = append(w.steps, brk)
	} else {
		left := w.remaining(now)
		if w.steps[w.index].Seconds == 0 {
			left = 0
		}
		w.steps = append(w.steps[:w.index], append([]signal.WorkoutStep{brk}, w.steps[w.index:]...)...)
		w.resumeIndex, w.resumeLeft = w.index+1, left
	}
	w.running = true
	w.left = stepLength(brk)
	w.endsAt = now.Add(w.left)
}

// state is the workout as sent to clients.
func (w *workout) state(now time.Time) *signal.Workout {
	return &signal.Workout{
		Title:       w.title,
		Steps:       w.steps,
		Index:       w.index,
		Running:     w.running,
		RemainingMs: w.remaining(now).Milliseconds(),
		Finished:    w.index >= len(w.steps),
	}
}

// workoutState is the room's workout now, or nil.
func (rm *room) workoutState() *signal.Workout {
	rm.wmu.Lock()
	defer rm.wmu.Unlock()
	if rm.workout == nil {
		return nil
	}
	return rm.workout.state(time.Now())
}

func (rm *room) broadcastWorkout() {
	broadcast(rm.others(nil), signal.Message{Type: signal.TypeWorkout, Workout: rm.workoutState()})
}

// scheduleWorkout sets a timer for the end of the current step, if it's
// running and timed; when it fires, the workout moves on and everyone hears.
func (rm *room) scheduleWorkout() {
	rm.wmu.Lock()
	defer rm.wmu.Unlock()
	rm.stopTimerLocked()
	w := rm.workout
	if w == nil || !w.running || w.index >= len(w.steps) || w.steps[w.index].Seconds == 0 {
		return
	}
	gen := w.gen
	w.timer = time.AfterFunc(w.remaining(time.Now()), func() {
		rm.wmu.Lock()
		if rm.workout != w || w.gen != gen {
			rm.wmu.Unlock()
			return
		}
		// Carry on from when the step ended, not when the timer fired.
		w.enter(w.index+1, w.endsAt)
		rm.wmu.Unlock()
		rm.scheduleWorkout()
		rm.broadcastWorkout()
	})
}

// stopTimerLocked cancels the step timer. Called with rm.wmu held.
func (rm *room) stopTimerLocked() {
	if w := rm.workout; w != nil {
		w.gen++
		if w.timer != nil {
			w.timer.Stop()
			w.timer = nil
		}
	}
}
