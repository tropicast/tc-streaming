// Command loadtest simulates stream listeners for the load and soak tests
// (#12). Each listener holds one HTTP/1.1 connection, like a separate
// player, reads the stream continuously and reconnects after a drop.
//
//	loadtest -url https://listen.example.com/stations/42/live.opus -listeners 700 \
//	         -url https://listen.example.com/stations/42/live.mp3 -listeners 700 \
//	         -ramp 5m -hold 10m
//
// It prints one line every -every and a JSON summary at the end.
package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type multi []string

func (m *multi) String() string     { return strings.Join(*m, ",") }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

type ints []int

func (m *ints) String() string { return fmt.Sprint(*m) }
func (m *ints) Set(v string) error {
	var n int
	_, err := fmt.Sscan(v, &n)
	*m = append(*m, n)
	return err
}

type stats struct {
	active, bytes, connects, drops, refused, errors atomic.Int64
	mu                                              sync.Mutex
	ttfb                                            []time.Duration
}

func (s *stats) addTTFB(d time.Duration) {
	s.mu.Lock()
	s.ttfb = append(s.ttfb, d)
	s.mu.Unlock()
}

func (s *stats) ttfbPercentile(p float64) time.Duration {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.ttfb) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), s.ttfb...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	return sorted[int(float64(len(sorted)-1)*p)]
}

var (
	insecure = flag.Bool("insecure", false, "skip TLS verification (local tests only)")
	connect  = flag.String("connect", "", "host:port to dial instead of the URL's host (local tests)")
)

func newClient() *http.Client {
	dialer := &net.Dialer{Timeout: 15 * time.Second}
	dial := dialer.DialContext
	if *connect != "" {
		dial = func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, *connect)
		}
	}
	return &http.Client{Transport: &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: *insecure}, //nolint:gosec // opt-in for local tests
		// HTTP/1.1 and one connection per listener, like separate players.
		TLSNextProto:        map[string]func(string, *tls.Conn) http.RoundTripper{},
		DisableKeepAlives:   true,
		MaxConnsPerHost:     0,
		TLSHandshakeTimeout: 15 * time.Second,
		DialContext:         dial,
	}}
}

// listen streams url until ctx ends, reconnecting after drops.
func listen(ctx context.Context, url string, s *stats) {
	client := newClient()
	buf := make([]byte, 32*1024)
	for ctx.Err() == nil {
		start := time.Now()
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		req.Header.Set("User-Agent", "tropicast-loadtest/1")
		resp, err := client.Do(req)
		if err != nil {
			if ctx.Err() == nil {
				s.errors.Add(1)
				sleep(ctx, time.Second)
			}
			continue
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			s.refused.Add(1)
			sleep(ctx, 2*time.Second)
			continue
		}
		s.connects.Add(1)
		s.active.Add(1)
		first := true
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				if first {
					s.addTTFB(time.Since(start))
					first = false
				}
				s.bytes.Add(int64(n))
			}
			if err != nil {
				// EOF or a reset while the test still runs: the server
				// dropped this listener.
				if ctx.Err() == nil {
					s.drops.Add(1)
				}
				break
			}
		}
		resp.Body.Close()
		s.active.Add(-1)
		sleep(ctx, time.Second)
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

func main() {
	var urls multi
	var counts ints
	flag.Var(&urls, "url", "stream URL (repeat; pairs with -listeners)")
	flag.Var(&counts, "listeners", "listeners for the preceding -url (repeat)")
	ramp := flag.Duration("ramp", time.Minute, "time to start all listeners")
	hold := flag.Duration("hold", 5*time.Minute, "time to hold full load after the ramp")
	every := flag.Duration("every", 10*time.Second, "report interval")
	flag.Parse()
	if len(urls) == 0 || len(urls) != len(counts) {
		fmt.Fprintln(os.Stderr, "give one -listeners per -url")
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	ctx, cancel := context.WithTimeout(ctx, *ramp+*hold)
	defer cancel()

	total := 0
	for _, c := range counts {
		total += c
	}
	per := make([]*stats, len(urls))
	for i := range per {
		per[i] = &stats{}
	}
	var wg sync.WaitGroup
	go func() { // ramp: start listeners evenly over -ramp, interleaving URLs
		interval := time.Duration(0)
		if total > 1 {
			interval = *ramp / time.Duration(total)
		}
		started := make([]int, len(urls))
		for n := 0; n < total && ctx.Err() == nil; {
			for i := range urls {
				if started[i] < counts[i] {
					started[i]++
					n++
					wg.Add(1)
					go func(i int) { defer wg.Done(); listen(ctx, urls[i], per[i]) }(i)
					sleep(ctx, interval)
				}
			}
		}
	}()

	begin := time.Now()
	last := make([]int64, len(urls))
	ticker := time.NewTicker(*every)
	defer ticker.Stop()
	fmt.Println("elapsed  url  active  Mbit/s  connects  drops  refused  errors  ttfb_p95")
	for done := false; !done; {
		select {
		case <-ctx.Done():
			done = true
		case <-ticker.C:
		}
		for i, s := range per {
			b := s.bytes.Load()
			mbps := float64(b-last[i]) * 8 / every.Seconds() / 1e6
			last[i] = b
			fmt.Printf("%6.0fs  %d  %6d  %6.1f  %8d  %5d  %7d  %6d  %v\n",
				time.Since(begin).Seconds(), i, s.active.Load(), mbps, s.connects.Load(),
				s.drops.Load(), s.refused.Load(), s.errors.Load(), s.ttfbPercentile(0.95).Round(time.Millisecond))
		}
	}
	wg.Wait()

	type result struct {
		URL                                     string
		Listeners                               int
		Bytes, Connects, Drops, Refused, Errors int64
		MBPerListenerHour                       float64
		TTFBp50, TTFBp95                        string
	}
	var out []result
	elapsed := time.Since(begin).Hours()
	for i, s := range per {
		listenerHours := float64(counts[i]) * (elapsed - ramp.Hours()/2)
		out = append(out, result{
			URL: urls[i], Listeners: counts[i], Bytes: s.bytes.Load(), Connects: s.connects.Load(),
			Drops: s.drops.Load(), Refused: s.refused.Load(), Errors: s.errors.Load(),
			MBPerListenerHour: float64(s.bytes.Load()) / 1e6 / listenerHours,
			TTFBp50:           s.ttfbPercentile(0.5).Round(time.Millisecond).String(),
			TTFBp95:           s.ttfbPercentile(0.95).Round(time.Millisecond).String(),
		})
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	_ = enc.Encode(out)
}
