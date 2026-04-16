// Upstream Zig commit watcher for Sig.
// Polls Codeberg API every 30s, fires GitHub repository_dispatch on new commits.
// Deploy as Cloud Run service with GITHUB_TOKEN and optional POLL_INTERVAL env vars.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type CodebergCommit struct {
	SHA string `json:"sha"`
}

var (
	lastSeen     string
	ghToken      string
	ghRepo       = "SB0LTD/sig"
	cbAPI        = "https://codeberg.org/api/v1/repos/zig/zig/branches/master"
	pollInterval = 30 * time.Second
)

func getLatestCommit() (string, error) {
	req, _ := http.NewRequest("GET", cbAPI, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("codeberg API %d: %s", resp.StatusCode, string(body[:min(len(body), 200)]))
	}
	var result struct {
		Commit struct {
			ID string `json:"id"`
		} `json:"commit"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	return result.Commit.ID, nil
}

func triggerSync(commitSHA string) error {
	payload := fmt.Sprintf(`{"event_type":"upstream-push","client_payload":{"commit":"%s"}}`, commitSHA)
	req, _ := http.NewRequest("POST",
		fmt.Sprintf("https://api.github.com/repos/%s/dispatches", ghRepo),
		strings.NewReader(payload))
	req.Header.Set("Authorization", "Bearer "+ghToken)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 204 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("github dispatch %d: %s", resp.StatusCode, string(body[:min(len(body), 200)]))
	}
	return nil
}

func poll() {
	sha, err := getLatestCommit()
	if err != nil {
		log.Printf("poll error: %v", err)
		return
	}
	if sha == lastSeen {
		return
	}
	if lastSeen == "" {
		// First run — just record, don't trigger
		log.Printf("initialized: %s", sha[:12])
		lastSeen = sha
		return
	}
	log.Printf("new commit: %s (was %s)", sha[:12], lastSeen[:12])
	if err := triggerSync(sha); err != nil {
		log.Printf("dispatch error: %v", err)
		return
	}
	log.Printf("dispatched upstream-push for %s", sha[:12])
	lastSeen = sha
}

func main() {
	ghToken = os.Getenv("GITHUB_TOKEN")
	if ghToken == "" {
		log.Fatal("GITHUB_TOKEN required")
	}
	if r := os.Getenv("GITHUB_REPO"); r != "" {
		ghRepo = r
	}
	if d := os.Getenv("POLL_INTERVAL"); d != "" {
		if parsed, err := time.ParseDuration(d); err == nil {
			pollInterval = parsed
		}
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// Health endpoint for Cloud Run
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"status":"ok","last_seen":"%s","repo":"%s"}`, lastSeen, ghRepo)
	})

	// Start poller in background
	go func() {
		log.Printf("polling %s every %s", cbAPI, pollInterval)
		for {
			poll()
			time.Sleep(pollInterval)
		}
	}()

	log.Printf("listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
