//go:build windows

// checkwv - verify WavPack (.wv) files in parallel using "wvunpack -vv",
// with a CheckWavpackFiles-style display (per-folder listing, colored OK/BAD,
// "n/total" counters) plus an animated progress bar with elapsed time and ETA.
//
// Build:  go mod init checkwv && go build -o checkwv.exe
// Usage:  checkwv.exe [--threads N] [--plain] [--md5] [-vN ...] [--wvunpack PATH] [folder-or-file ...]
//
// wvunpack.exe is looked for in the same folder as this executable first,
// then in PATH. Bad files are written to BadFiles.txt (and, with --md5, files
// without an MD5 to NoMD5Files.txt, files written by WavPack version N, given
// with -vN, to WavPackVNFiles.txt) in the first scan path, as they are found.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

// ---------------------------------------------------------------- console --

var (
	kernel32               = syscall.NewLazyDLL("kernel32.dll")
	procGetConsoleMode     = kernel32.NewProc("GetConsoleMode")
	procSetConsoleMode     = kernel32.NewProc("SetConsoleMode")
	procGetConsoleOutputCP = kernel32.NewProc("GetConsoleOutputCP")
	procSetConsoleOutputCP = kernel32.NewProc("SetConsoleOutputCP")
	procGetConsoleTitle    = kernel32.NewProc("GetConsoleTitleW")
	procSetConsoleTitle    = kernel32.NewProc("SetConsoleTitleW")
	oldOutputCP            uintptr
	oldTitle               string
)

// initConsole switches the console to UTF-8 (so Japanese/Chinese file names
// display correctly) and enables ANSI colors. It returns false when stdout is
// not a console (e.g. redirected to a file) or ANSI cannot be enabled.
func initConsole() bool {
	h := os.Stdout.Fd()
	var mode uint32
	if r, _, _ := procGetConsoleMode.Call(h, uintptr(unsafe.Pointer(&mode))); r == 0 {
		return false
	}
	oldOutputCP, _, _ = procGetConsoleOutputCP.Call()
	saveTitle()
	procSetConsoleOutputCP.Call(65001)
	const enableVT = 0x0004 // ENABLE_VIRTUAL_TERMINAL_PROCESSING
	r, _, _ := procSetConsoleMode.Call(h, uintptr(mode|enableVT))
	return r != 0
}

func restoreConsole() {
	if oldOutputCP != 0 {
		procSetConsoleOutputCP.Call(oldOutputCP)
	}
	if oldTitle != "" {
		setTitle(oldTitle)
	}
}

func saveTitle() {
	buf := make([]uint16, 1024)
	n, _, _ := procGetConsoleTitle.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n > 0 && int(n) <= len(buf) {
		oldTitle = syscall.UTF16ToString(buf[:n])
	}
}

func setTitle(s string) {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		return
	}
	procSetConsoleTitle.Call(uintptr(unsafe.Pointer(p)))
}

// runWV runs wvunpack with its own hidden console. Otherwise every wvunpack
// process writes its per-file percentage into our window title.
func runWV(wv string, args ...string) ([]byte, error) {
	cmd := exec.Command(wv, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW
	return cmd.CombinedOutput()
}

// ---------------------------------------------------------------- helpers --

type badFile struct {
	path string
	msg  string
}

// listWriter appends paths to a list file (UTF-8 with BOM, CRLF) as they are
// found. The file is created on the first entry, truncating any old one, and
// every entry goes straight to the OS, so the list survives Ctrl-C or a crash.
// If the file cannot be created in dir, %TEMP%\TEMP_<name>.txt is used.
// Not safe for concurrent use: call it with the console mutex held.
type listWriter struct {
	name   string // "BadFiles" or "NoMD5Files"
	dir    string
	f      *os.File
	path   string // where the list actually went (empty until first entry)
	failed bool
}

func (w *listWriter) add(p string) {
	if w.failed {
		return
	}
	if w.f == nil {
		target := filepath.Join(w.dir, w.name+".txt")
		f, err := os.Create(target)
		if err != nil {
			target = filepath.Join(os.TempDir(), "TEMP_"+w.name+".txt")
			if f, err = os.Create(target); err != nil {
				w.failed = true
				fmt.Fprintln(os.Stderr, "Could not write "+w.name+".txt:", err)
				return
			}
		}
		f.WriteString("\xEF\xBB\xBF")
		w.f, w.path = f, target
	}
	w.f.WriteString(p + "\r\n")
}

func (w *listWriter) close() {
	if w.f != nil {
		w.f.Close()
	}
}

// md5RE matches the "original md5:" line printed by "wvunpack -s" (only present
// when the file stores an MD5). Anchored so a file name that happens to look
// like a hash cannot trigger a false match.
var md5RE = regexp.MustCompile(`(?im)^original md5:\s*[0-9a-f]{32}`)

// verRE matches the "encoder version:" line printed by "wvunpack -s".
var verRE = regexp.MustCompile(`(?im)^encoder version:\s*(\d+)`)

// verArgRE matches the command-line forms -v4 / --v4 (Go's flag package cannot
// parse a value glued to a flag name, so these are picked out before flag.Parse).
var verArgRE = regexp.MustCompile(`^--?v(\d+)$`)

func findWvunpack(explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	if exe, err := os.Executable(); err == nil {
		local := filepath.Join(filepath.Dir(exe), "wvunpack.exe")
		if st, err := os.Stat(local); err == nil && !st.IsDir() {
			return local, nil
		}
	}
	return exec.LookPath("wvunpack.exe")
}

func isSkippedDir(name string) bool {
	return strings.EqualFold(name, "$RECYCLE.BIN") ||
		strings.EqualFold(name, "System Volume Information")
}

// scan walks the roots and returns every .wv file, sorted folder by folder.
func scan(roots []string, found *int64) []string {
	var list []string
	for _, root := range roots {
		filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				if d != nil && d.IsDir() {
					return filepath.SkipDir // unreadable folder: skip it
				}
				return nil
			}
			if d.IsDir() {
				if p != root && isSkippedDir(d.Name()) {
					return filepath.SkipDir
				}
				return nil
			}
			if strings.EqualFold(filepath.Ext(p), ".wv") {
				list = append(list, p)
				atomic.AddInt64(found, 1)
			}
			return nil
		})
	}
	sort.SliceStable(list, func(i, j int) bool {
		di, dj := strings.ToLower(filepath.Dir(list[i])), strings.ToLower(filepath.Dir(list[j]))
		if di != dj {
			return di < dj
		}
		return strings.ToLower(filepath.Base(list[i])) < strings.ToLower(filepath.Base(list[j]))
	})
	return list
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		s = s[:i]
	}
	return s
}

func fmtDur(d time.Duration) string {
	s := int(d.Round(time.Second) / time.Second)
	if s < 0 {
		s = 0
	}
	if h := s / 3600; h > 0 {
		return fmt.Sprintf("%d:%02d:%02d", h, s/60%60, s%60)
	}
	return fmt.Sprintf("%02d:%02d", s/60, s%60)
}

func progressBar(done, total, width int) string {
	if total <= 0 {
		return strings.Repeat(" ", width)
	}
	filled := done * width / total
	if filled >= width {
		return strings.Repeat("=", width)
	}
	return strings.Repeat("=", filled) + ">" + strings.Repeat(" ", width-filled-1)
}

// ------------------------------------------------------------------- main --

func main() {
	os.Exit(run())
}

func run() int {
	threads := flag.Int("threads", 4, "number of files to verify simultaneously")
	wvPath := flag.String("wvunpack", "", "path to wvunpack.exe (default: next to this exe, then PATH)")
	plain := flag.Bool("plain", false, "no colors or animation (automatic when output is redirected)")
	MD5Check := flag.Bool("md5", false, "also warn about files without an internal MD5 checksum (one extra wvunpack -s call per file)")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [--threads N] [--plain] [--md5] [-vN ...] [--wvunpack PATH] [folder-or-file ...]\n",
			filepath.Base(os.Args[0]))
		flag.PrintDefaults()
		fmt.Fprintln(os.Stderr, "  -vN\n    \twarn about (and list) files written by WavPack version N, e.g. -v4; may be repeated (-v3 -v4)")
	}

	// -vN options: pull them out, then let the flag package parse the rest.
	verWarn := map[int]bool{}
	var restArgs []string
	for _, a := range os.Args[1:] {
		if m := verArgRE.FindStringSubmatch(a); m != nil {
			n, _ := strconv.Atoi(m[1])
			verWarn[n] = true
			continue
		}
		restArgs = append(restArgs, a)
	}
	flag.CommandLine.Parse(restArgs)

	if *threads < 1 {
		*threads = 1
	}
	roots := flag.Args()
	if len(roots) == 0 {
		roots = []string{"."}
	}

	listDir := roots[0]
	if st, err := os.Stat(listDir); err == nil && !st.IsDir() {
		listDir = filepath.Dir(listDir)
	}
	badList := &listWriter{name: "BadFiles", dir: listDir}
	noMD5List := &listWriter{name: "NoMD5Files", dir: listDir}
	defer badList.close()
	defer noMD5List.close()

	verList := make([]int, 0, len(verWarn))
	for v := range verWarn {
		verList = append(verList, v)
	}
	sort.Ints(verList)
	verLists := map[int]*listWriter{}
	for _, v := range verList {
		w := &listWriter{name: fmt.Sprintf("WavPackV%dFiles", v), dir: listDir}
		verLists[v] = w
		defer w.close()
	}

	fancy := initConsole() && !*plain

	var cleanupOnce sync.Once
	cleanup := func() {
		cleanupOnce.Do(func() {
			if fancy {
				os.Stdout.WriteString("\r\x1b[2K\x1b[?25h") // clear status line, show cursor
			}
			restoreConsole()
		})
	}
	defer cleanup()

	paint := func(code, s string) string {
		if !fancy {
			return s
		}
		return "\x1b[" + code + "m" + s + "\x1b[0m"
	}

	wv, err := findWvunpack(*wvPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot find wvunpack.exe:", err)
		return 2
	}
	fmt.Printf("Using %s with %d worker(s)\n", wv, *threads)
	if *MD5Check {
		fmt.Println("Missing-MD5 warning enabled")
	}
	if len(verList) > 0 {
		names := make([]string, len(verList))
		for i, v := range verList {
			names[i] = "v" + strconv.Itoa(v)
		}
		fmt.Println("WavPack version warning enabled: " + strings.Join(names, ", "))
	}

	if fancy {
		os.Stdout.WriteString("\x1b[?25l") // hide cursor while animating
	}

	var (
		mu    sync.Mutex // guards everything below and all console output
		total int
		done  int
		frame int
		bad   []badFile
		noMD5 []string
		verCount  = map[int]int{} // files found per watched WavPack version
		noVerLine int             // files whose version could not be read
		start     = time.Now()
	)
	spinner := []byte(`|/-\`)

	// Ctrl-C: restore the console and quit.
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, os.Interrupt)
	go func() {
		<-sigc
		mu.Lock()
		cleanup()
		fmt.Println("Interrupted.")
		os.Exit(130)
	}()

	// ---- phase 1: build the file list (like the original), with a spinner.
	var found int64
	var files []string
	scanDone := make(chan struct{})
	go func() {
		files = scan(roots, &found)
		close(scanDone)
	}()
	tick := time.NewTicker(100 * time.Millisecond)
scanLoop:
	for {
		select {
		case <-scanDone:
			break scanLoop
		case <-tick.C:
			if fancy {
				mu.Lock()
				frame++
				os.Stdout.WriteString(fmt.Sprintf("\r\x1b[2K%s",
					paint("90", fmt.Sprintf("%c Scanning... %d .wv file(s) found",
						spinner[frame%len(spinner)], atomic.LoadInt64(&found)))))
				mu.Unlock()
			}
		}
	}
	tick.Stop()

	total = len(files)
	if fancy {
		os.Stdout.WriteString("\r\x1b[2K")
	}
	if total == 0 {
		fmt.Println("No .wv files found.")
		return 0
	}
	fmt.Printf("Found %d .wv file(s) in %s\n", total, time.Since(start).Round(time.Millisecond))
	numW := len(strconv.Itoa(total))
	start = time.Now() // timing for ETA starts with the actual checking

	// statusLine must be called with mu held.
	statusLine := func() string {
		elapsed := time.Since(start)
		eta := "--:--"
		if done > 0 {
			eta = fmtDur(time.Duration(float64(elapsed) / float64(done) * float64(total-done)))
		}
		return paint("90", fmt.Sprintf("%c [%s] %3d%%  %*d/%d  %s  ETA %s",
			spinner[frame%len(spinner)], progressBar(done, total, 24), done*100/total,
			numW, done, total, fmtDur(elapsed), eta))
	}

	// render prints finished lines (if any) and redraws the status line.
	// Must be called with mu held.
	render := func(lines ...string) {
		var sb strings.Builder
		if fancy {
			sb.WriteString("\r\x1b[2K")
		}
		for _, l := range lines {
			sb.WriteString(l)
			sb.WriteString("\n")
		}
		if fancy {
			sb.WriteString(statusLine())
			setTitle(fmt.Sprintf("checkwv %d%% (%d/%d)", done*100/total, done, total))
		}
		os.Stdout.WriteString(sb.String())
	}

	// ---- phase 2: verify in parallel.
	stopTick := make(chan struct{})
	tickDone := make(chan struct{})
	go func() {
		defer close(tickDone)
		if !fancy {
			return
		}
		t := time.NewTicker(100 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stopTick:
				return
			case <-t.C:
				mu.Lock()
				frame++
				render()
				mu.Unlock()
			}
		}
	}()

	jobs := make(chan string)
	var wg sync.WaitGroup
	lastDir := ""
	for i := 0; i < *threads; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range jobs {
				out, err := runWV(wv, "-vv", p)

				// Files that decode fine: optionally look at the header info too.
				// "wvunpack -s" does not decode, so it is fast.
				noMD5Here, verHere, verUnknown, ver := false, false, false, 0
				if err == nil && (*MD5Check || len(verWarn) > 0) {
					sout, serr := runWV(wv, "-s", p)
					if serr == nil {
						noMD5Here = *MD5Check && !md5RE.Match(sout)
						if len(verWarn) > 0 {
							if m := verRE.FindSubmatch(sout); m == nil {
								verUnknown = true
							} else if v, _ := strconv.Atoi(string(m[1])); verWarn[v] {
								verHere, ver = true, v
							}
						}
					}
				}

				mu.Lock()
				done++
				var lines []string
				if dir := filepath.Dir(p); dir != lastDir {
					lastDir = dir
					lines = append(lines, "", paint("36", "> "+dir+":"))
				}
				name := filepath.Base(p)
				if err == nil {
					var notes []string
					if noMD5Here {
						noMD5 = append(noMD5, p)
						noMD5List.add(p)
						notes = append(notes, "no MD5 checksum stored")
					}
					if verHere {
						verCount[ver]++
						verLists[ver].add(p)
						notes = append(notes, fmt.Sprintf("WavPack v%d file", ver))
					}
					if verUnknown {
						noVerLine++
					}
					if len(notes) > 0 {
						lines = append(lines, fmt.Sprintf("%*d/%d:  %s  %s",
							numW, done, total, name, paint("33", "OK, but "+strings.Join(notes, "; "))))
					} else {
						lines = append(lines, fmt.Sprintf("%*d/%d:  %s  %s",
							numW, done, total, name, paint("32", "OK")))
					}
				} else {
					msg := firstLine(string(out))
					if msg == "" {
						msg = err.Error()
					}
					bad = append(bad, badFile{p, msg})
					badList.add(p)
					lines = append(lines,
						fmt.Sprintf("%*d/%d:  %s  %s", numW, done, total, name, paint("31;1", "BAD")),
						"    "+paint("31", msg))
				}
				render(lines...)
				mu.Unlock()
			}
		}()
	}
	for _, p := range files {
		jobs <- p
	}
	close(jobs)
	wg.Wait()
	close(stopTick)
	<-tickDone

	// ---- summary
	mu.Lock()
	if fancy {
		os.Stdout.WriteString("\r\x1b[2K")
	}
	fmt.Println()
	summary := fmt.Sprintf("Done: %d file(s) checked, %d bad", total, len(bad))
	warnings := noVerLine
	if *MD5Check {
		summary += fmt.Sprintf(", %d without MD5", len(noMD5))
		warnings += len(noMD5)
	}
	for _, v := range verList {
		summary += fmt.Sprintf(", %d WavPack v%d", verCount[v], v)
		warnings += verCount[v]
	}
	if noVerLine > 0 {
		summary += fmt.Sprintf(", %d with unreadable version", noVerLine)
	}
	summary += fmt.Sprintf(", %s elapsed", time.Since(start).Round(time.Second))
	switch {
	case len(bad) > 0:
		fmt.Println(paint("31;1", summary))
	case warnings > 0:
		fmt.Println(paint("33;1", summary))
	default:
		fmt.Println(paint("32;1", summary))
	}
	mu.Unlock()

	// The lists were written incrementally; just say where they are.
	if badList.path != "" {
		fmt.Println("List written to", badList.path)
	}
	if noMD5List.path != "" {
		fmt.Println("List written to", noMD5List.path)
	}
	for _, v := range verList {
		if verLists[v].path != "" {
			fmt.Println("List written to", verLists[v].path)
		}
	}
	if len(bad) > 0 {
		return 1
	}
	return 0
}
