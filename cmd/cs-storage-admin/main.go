package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"cs-storage/internal/admin"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "restore":
		restore(os.Args[2:])
	case "backups":
		backups(os.Args[2:])
	case "render-compose":
		renderCompose(os.Args[2:])
	case "deploy-stack":
		deployStack(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
}

func restore(args []string) {
	fs := flag.NewFlagSet("restore", flag.ExitOnError)
	source := fs.String("source", "", "exact rclone source, for example remote:backups/vol1/20260521-120000")
	sourceRoot := fs.String("source-root", "", "backup root used with -volume -latest, for example remote:backups")
	latest := fs.Bool("latest", false, "with -source-root and -volume, restore the lexicographically latest backup directory")
	target := fs.String("target", "", "local directory to restore into")
	volume := fs.String("volume", "", "volume name; used with -root when -target is omitted")
	root := fs.String("root", "/mnt/cs_storage/vols", "volume root used with -volume")
	rcloneBin := fs.String("rclone", "rclone", "rclone binary path")
	rcloneConfig := fs.String("rclone-config", "", "optional rclone config path")
	backupSuffix := fs.String("backup-suffix", ".BAK", "suffix appended before timestamp for existing target backup")
	dryRun := fs.Bool("dry-run", false, "show backup/restore plan without changing files")
	rollback := fs.Bool("rollback-on-fail", false, "rename backup back if rclone restore fails")
	extra := fs.String("rclone-args", "", "extra rclone args split by spaces")
	timeout := fs.Duration("timeout", 0, "optional restore timeout, for example 2h")
	_ = fs.Parse(args)

	dst := *target
	if dst == "" && *volume != "" {
		dst = strings.TrimRight(*root, "/") + "/" + *volume + "/mount"
	}
	extraArgs := splitArgs(*extra)
	ctx, cancel := timeoutContext(*timeout)
	defer cancel()
	restoreSource := *source
	if *latest {
		var latestName string
		var err error
		restoreSource, latestName, err = admin.LatestBackupSource(ctx, admin.LatestBackupSourceOptions{
			Root:         *sourceRoot,
			Volume:       *volume,
			RcloneBinary: *rcloneBin,
			RcloneConfig: *rcloneConfig,
			ExtraArgs:    extraArgs,
		})
		if err != nil {
			log.Fatal(err)
		}
		fmt.Printf("selected latest backup: %s (%s)\n", restoreSource, latestName)
	}
	res, err := admin.Restore(ctx, admin.RestoreOptions{
		Source:         restoreSource,
		Target:         dst,
		RcloneBinary:   *rcloneBin,
		RcloneConfig:   *rcloneConfig,
		BackupSuffix:   *backupSuffix,
		Timestamp:      time.Now(),
		DryRun:         *dryRun,
		RollbackOnFail: *rollback,
		ExtraArgs:      extraArgs,
	})
	if err != nil {
		log.Fatal(err)
	}
	if res.BackupPath != "" {
		fmt.Printf("existing target moved to: %s\n", res.BackupPath)
	}
	if res.DryRun {
		fmt.Printf("dry run: would restore %s to %s\n", res.Source, res.Target)
		return
	}
	fmt.Printf("restored %s to %s\n", res.Source, res.Target)
}

func backups(args []string) {
	fs := flag.NewFlagSet("backups", flag.ExitOnError)
	source := fs.String("source", "", "rclone backup root, for example remote:backups")
	rcloneBin := fs.String("rclone", "rclone", "rclone binary path")
	rcloneConfig := fs.String("rclone-config", "", "optional rclone config path")
	extra := fs.String("rclone-args", "", "extra rclone args split by spaces")
	timeout := fs.Duration("timeout", 0, "optional list timeout, for example 30s")
	_ = fs.Parse(args)
	ctx, cancel := timeoutContext(*timeout)
	defer cancel()
	items, err := admin.ListBackups(ctx, admin.ListBackupsOptions{
		Source:       *source,
		RcloneBinary: *rcloneBin,
		RcloneConfig: *rcloneConfig,
		ExtraArgs:    splitArgs(*extra),
	})
	if err != nil {
		log.Fatal(err)
	}
	for _, item := range items {
		fmt.Println(item)
	}
}

func renderCompose(args []string) {
	fs := flag.NewFlagSet("render-compose", flag.ExitOnError)
	input := fs.String("in", "-", "input Compose/Stack YAML path, or - for stdin")
	output := fs.String("out", "-", "output YAML path, or - for stdout")
	_ = fs.Parse(args)

	var r *os.File
	if *input == "-" {
		r = os.Stdin
	} else {
		f, err := os.Open(*input)
		if err != nil {
			log.Fatal(err)
		}
		defer f.Close()
		r = f
	}
	var w *os.File
	if *output == "-" {
		w = os.Stdout
	} else {
		f, err := os.Create(*output)
		if err != nil {
			log.Fatal(err)
		}
		defer f.Close()
		w = f
	}
	if err := admin.RenderCompose(r, w); err != nil {
		log.Fatal(err)
	}
}

func deployStack(args []string) {
	fs := flag.NewFlagSet("deploy-stack", flag.ExitOnError)
	input := fs.String("in", "", "input Compose/Stack YAML path")
	stack := fs.String("stack", "", "Docker Stack name")
	dockerBin := fs.String("docker", "docker", "docker binary path")
	renderedOut := fs.String("rendered-out", "", "optional path to keep the rendered Compose file")
	withRegistryAuth := fs.Bool("with-registry-auth", false, "pass --with-registry-auth to docker stack deploy")
	prune := fs.Bool("prune", false, "pass --prune to docker stack deploy")
	resolveImage := fs.String("resolve-image", "", "optional docker stack deploy --resolve-image value")
	detach := fs.String("detach", "", "optional docker stack deploy --detach value: true or false")
	_ = fs.Parse(args)
	if *input == "" || *stack == "" {
		fs.Usage()
		os.Exit(2)
	}

	rendered, cleanup, err := renderComposeFile(*input, *renderedOut)
	if err != nil {
		log.Fatal(err)
	}
	defer cleanup()

	dockerArgs := []string{"stack", "deploy", "-c", rendered}
	if *withRegistryAuth {
		dockerArgs = append(dockerArgs, "--with-registry-auth")
	}
	if *prune {
		dockerArgs = append(dockerArgs, "--prune")
	}
	if *resolveImage != "" {
		dockerArgs = append(dockerArgs, "--resolve-image", *resolveImage)
	}
	if *detach != "" {
		dockerArgs = append(dockerArgs, "--detach="+*detach)
	}
	dockerArgs = append(dockerArgs, *stack)
	cmd := exec.Command(*dockerBin, dockerArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}

func renderComposeFile(input string, renderedOut string) (string, func(), error) {
	in, err := os.Open(input)
	if err != nil {
		return "", func() {}, err
	}
	defer in.Close()
	if renderedOut != "" {
		out, err := os.Create(renderedOut)
		if err != nil {
			return "", func() {}, err
		}
		err = admin.RenderCompose(in, out)
		closeErr := out.Close()
		if err != nil {
			return "", func() {}, err
		}
		if closeErr != nil {
			return "", func() {}, closeErr
		}
		return renderedOut, func() {}, nil
	}
	dir, err := os.MkdirTemp("", "cs-storage-stack-*")
	if err != nil {
		return "", func() {}, err
	}
	cleanup := func() { _ = os.RemoveAll(dir) }
	path := filepath.Join(dir, "stack.rendered.yml")
	out, err := os.Create(path)
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	err = admin.RenderCompose(in, out)
	closeErr := out.Close()
	if err != nil {
		cleanup()
		return "", func() {}, err
	}
	if closeErr != nil {
		cleanup()
		return "", func() {}, closeErr
	}
	return path, cleanup, nil
}

func splitArgs(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return strings.Fields(v)
}

func timeoutContext(timeout time.Duration) (context.Context, context.CancelFunc) {
	if timeout <= 0 {
		return context.WithCancel(context.Background())
	}
	return context.WithTimeout(context.Background(), timeout)
}

func usage() {
	fmt.Fprintf(os.Stderr, "Usage:\n  cs-storage-admin backups -source <remote:path> [options]\n  cs-storage-admin restore (-source <remote:path> | -source-root <remote:path> -latest) (-target <dir> | -volume <name> [-root <dir>]) [options]\n  cs-storage-admin render-compose -in stack.yml -out stack.rendered.yml\n  cs-storage-admin deploy-stack -in stack.yml -stack <name> [options]\n")
}
