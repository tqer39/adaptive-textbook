package harness

import (
	"encoding/json"
	"errors"
	"sort"
	"time"
)

// IncludedQuota is a snapshot, not a reservation or a per-turn billing guarantee.
// Only nonsecret quota metadata is retained with the operation evidence.
type IncludedQuota struct {
	CheckedAt           string           `json:"checkedAt"`
	Plan                string           `json:"plan"`
	Windows             []IncludedWindow `json:"windows"`
	CreditsPresent      bool             `json:"creditsPresent"`
	HasCredits          bool             `json:"hasCredits"`
	UnlimitedCredits    bool             `json:"unlimitedCredits"`
	SpendControlUnknown bool             `json:"spendControlUnknown"`
}

type IncludedWindow struct {
	Bucket          string `json:"bucket"`
	Window          string `json:"window"`
	UsedPercent     int    `json:"usedPercent"`
	DurationMinutes int64  `json:"durationMinutes"`
	ResetsAt        int64  `json:"resetsAt"`
}

type rateWindow struct {
	UsedPercent *int   `json:"usedPercent"`
	Duration    *int64 `json:"windowDurationMins"`
	ResetsAt    *int64 `json:"resetsAt"`
}
type rateSnapshot struct {
	PlanType  string      `json:"planType"`
	Primary   *rateWindow `json:"primary"`
	Secondary *rateWindow `json:"secondary"`
	Credits   *struct {
		HasCredits *bool `json:"hasCredits"`
		Unlimited  *bool `json:"unlimited"`
	} `json:"credits"`
	ReachedType  string `json:"rateLimitReachedType"`
	SpendReached *bool  `json:"spendControlReached"`
}

func includedQuota(plan string, data []byte, now time.Time) (*IncludedQuota, error) {
	if plan != "pro" && plan != "prolite" {
		return nil, errors.New("codex-personal-pro-required")
	}
	var response struct {
		Legacy  *rateSnapshot           `json:"rateLimits"`
		ByLimit map[string]rateSnapshot `json:"rateLimitsByLimitId"`
	}
	if json.Unmarshal(data, &response) != nil {
		return nil, errors.New("codex-quota-invalid")
	}
	buckets := response.ByLimit
	if buckets == nil && response.Legacy != nil {
		buckets = map[string]rateSnapshot{"legacy": *response.Legacy}
	}
	if len(buckets) == 0 {
		return nil, errors.New("codex-quota-unknown")
	}
	q := &IncludedQuota{CheckedAt: now.UTC().Format(time.RFC3339Nano), Plan: plan, Windows: []IncludedWindow{}, CreditsPresent: true}
	keys := make([]string, 0, len(buckets))
	for key := range buckets {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		b := buckets[key]
		if b.PlanType != "" && b.PlanType != plan {
			return nil, errors.New("codex-quota-plan-mismatch")
		}
		if b.ReachedType != "" || (b.SpendReached != nil && *b.SpendReached) {
			return nil, errors.New("codex-quota-reached")
		}
		if b.SpendReached == nil {
			q.SpendControlUnknown = true
		}
		if b.Credits == nil || b.Credits.HasCredits == nil || b.Credits.Unlimited == nil {
			return nil, errors.New("codex-credit-state-unknown")
		}
		if *b.Credits.HasCredits || *b.Credits.Unlimited {
			return nil, errors.New("codex-additional-credits-refused")
		}
		count := 0
		for i, window := range []*rateWindow{b.Primary, b.Secondary} {
			if window == nil {
				continue
			}
			count++
			if window.UsedPercent == nil || window.Duration == nil || window.ResetsAt == nil || *window.UsedPercent < 0 || *window.UsedPercent >= 80 || *window.Duration <= 0 || *window.ResetsAt <= now.Unix() {
				return nil, errors.New("codex-included-quota-insufficient-or-unknown")
			}
			name := "primary"
			if i == 1 {
				name = "secondary"
			}
			q.Windows = append(q.Windows, IncludedWindow{Bucket: key, Window: name, UsedPercent: *window.UsedPercent, DurationMinutes: *window.Duration, ResetsAt: *window.ResetsAt})
		}
		if count == 0 {
			return nil, errors.New("codex-quota-window-unknown")
		}
	}
	return q, nil
}
