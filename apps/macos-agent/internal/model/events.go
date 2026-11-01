package model

import (
	"errors"
	"sync"
	"time"
)

const EventCapacity = 200

// Event 没有自由文本或任意 JSON 字段，避免误存口令、输入和原始网络错误。
// Sequence 是当前进程内的顺序；系统时间回调不改变事件顺序。
type Event struct {
	Sequence uint64 `json:"sequence"`
	At       int64  `json:"at"`
	Kind     string `json:"kind"`
	From     string `json:"from"`
	To       string `json:"to"`
	Code     string `json:"code"`
}

type EventPage struct {
	V              int     `json:"v"`
	AgentID        string  `json:"agent_id"`
	Session        string  `json:"session"`
	ObservedAt     int64   `json:"observed_at"`
	Capacity       int     `json:"capacity"`
	OldestSequence uint64  `json:"oldest_sequence"`
	LatestSequence uint64  `json:"latest_sequence"`
	NextAfter      uint64  `json:"next_after"`
	Truncated      bool    `json:"truncated"`
	HasMore        bool    `json:"has_more"`
	Events         []Event `json:"events"`
}

var ErrEventSession = errors.New("event_session_changed")
var ErrEventCursor = errors.New("event_cursor_ahead")

// Journal 是固定容量的环形缓冲。重启清空，既不写磁盘，也不无限增长。
type Journal struct {
	mu             sync.RWMutex
	agent, session string
	buffer         [EventCapacity]Event
	start, count   int
	sequence       uint64
}

func NewJournal(agent, session string) *Journal { return &Journal{agent: agent, session: session} }

func (j *Journal) Append(kind, from, to, code string, at int64) {
	if at <= 0 {
		at = time.Now().UnixMilli()
	}
	j.mu.Lock()
	defer j.mu.Unlock()
	j.sequence++
	event := Event{Sequence: j.sequence, At: at, Kind: kind, From: from, To: to, Code: code}
	index := (j.start + j.count) % EventCapacity
	if j.count == EventCapacity {
		j.start = (j.start + 1) % EventCapacity
	} else {
		j.count++
	}
	j.buffer[index] = event
}

// after=nil 返回最近 limit 条；提供 after 则按升序增量读取。
// session 用来识别重启，truncated 表示客户端落后于已经淘汰的历史。
func (j *Journal) Read(after *uint64, limit int, session string) (EventPage, error) {
	j.mu.RLock()
	defer j.mu.RUnlock()
	page := EventPage{V: 1, AgentID: j.agent, Session: j.session, ObservedAt: time.Now().UnixMilli(),
		Capacity: EventCapacity, LatestSequence: j.sequence, Events: []Event{}}
	if session != "" && session != j.session {
		return page, ErrEventSession
	}
	if after != nil && *after > j.sequence {
		return page, ErrEventCursor
	}
	if limit < 1 || limit > EventCapacity {
		return page, errors.New("invalid_event_limit")
	}
	if j.count == 0 {
		return page, nil
	}
	page.OldestSequence = j.buffer[j.start].Sequence
	first := 0
	if after == nil {
		if j.count > limit {
			first = j.count - limit
		}
	} else {
		page.NextAfter = *after
		page.Truncated = *after < page.OldestSequence-1
		for first < j.count && j.buffer[(j.start+first)%EventCapacity].Sequence <= *after {
			first++
		}
	}
	for i := first; i < j.count; i++ {
		if len(page.Events) == limit {
			page.HasMore = true
			break
		}
		page.Events = append(page.Events, j.buffer[(j.start+i)%EventCapacity])
	}
	if len(page.Events) > 0 {
		page.NextAfter = page.Events[len(page.Events)-1].Sequence
	}
	return page, nil
}
