package model

import (
	"fmt"
	"sync"
	"testing"
)

func TestJournalWrapPaginationAndRestart(t *testing.T) {
	j := NewJournal("mac-test", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	for i := 1; i <= 250; i++ {
		j.Append("did_wake", "sleeping", "awake", "", int64(1000-i))
	}
	page, err := j.Read(nil, 50, "")
	if err != nil || len(page.Events) != 50 || page.Events[0].Sequence != 201 || page.NextAfter != 250 || page.OldestSequence != 51 || page.HasMore || page.Truncated {
		t.Fatal(page, err)
	}
	page.Events[0].Kind = "mutated"
	after := uint64(0)
	page, _ = j.Read(&after, 40, j.session)
	if !page.Truncated || !page.HasMore || page.Events[0].Sequence != 51 || page.NextAfter != 90 {
		t.Fatal(page)
	}
	after = page.NextAfter
	page, _ = j.Read(&after, 200, j.session)
	if page.Truncated || page.HasMore || len(page.Events) != 160 || page.Events[110].Kind == "mutated" {
		t.Fatal("bad pagination or storage alias")
	}
	after = 250
	page, _ = j.Read(&after, 200, j.session)
	if len(page.Events) != 0 || page.NextAfter != 250 {
		t.Fatal(page)
	}
	after++
	if _, err := j.Read(&after, 10, j.session); err != ErrEventCursor {
		t.Fatal(err)
	}
	if _, err := j.Read(nil, 10, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"); err != ErrEventSession {
		t.Fatal(err)
	}
	for _, limit := range []int{0, -1, 201} {
		if _, err := j.Read(nil, limit, ""); err == nil {
			t.Fatal("invalid limit accepted")
		}
	}
	restarted := NewJournal(j.agent, "cccccccccccccccccccccccccccccccc")
	if _, err := restarted.Read(&after, 10, j.session); err != ErrEventSession {
		t.Fatal("old process cursor accepted")
	}
}

func TestJournalConcurrentReadersAndWriters(t *testing.T) {
	j := NewJournal("mac-test", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	var workers sync.WaitGroup
	for i := 0; i < 8; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for k := 0; k < 100; k++ {
				j.Append("mqtt_connected", "disconnected", "connected", "", 1)
				_, _ = j.Read(nil, 20, "")
			}
		}()
	}
	workers.Wait()
	page, _ := j.Read(nil, 200, "")
	if len(page.Events) != 200 || page.LatestSequence != 800 {
		t.Fatal(page)
	}
	for i, event := range page.Events {
		if event.Sequence != uint64(601+i) {
			t.Fatal(fmt.Sprint("event sequence ", event.Sequence))
		}
	}
}
