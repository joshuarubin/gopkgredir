package main // import "jrubin.io/gopkgredir"

import (
	"crypto/tls"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"strings"

	"github.com/codegangsta/cli"
	"github.com/rsc/letsencrypt"
)

const tpl = `<!DOCTYPE html>
<html>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<meta name="go-import" content="{{.ImportPrefix}}/{{.RepoName}} {{.VCS}} {{.RepoRoot}}/{{.RepoName}}" >
<meta http-equiv="refresh" content="0; url={{.RedirectURL}}">
</head>
<body>
Nothing to see here; <a href="{{.RedirectURL}}">move along</a>.
</body>
</html>
`

const (
	htmlTplName             = "html"
	defaultListenAddress    = "[::1]:80"
	defaultTLSListenAddress = "[::1]:443"
)

type config struct {
	ImportPrefix     string
	VCS              string
	RepoRoot         string
	RedirectURL      string
	ListenAddress    string
	TLSListenAddress string
	PublicTLSAddress string
	TLS              bool
}

type context struct {
	config
	RepoName    string
	RedirectURL string
}

var (
	name, version string
	html          *template.Template
	cfg           config
	manager       letsencrypt.Manager
	app           = cli.NewApp()
)

func init() {
	html = template.Must(template.New(htmlTplName).Parse(tpl))

	app.Name = name
	app.Version = version
	app.Usage = "a simple service to redirect \"go get\" properly"
	app.Authors = []cli.Author{{
		Name:  "Joshua Rubin",
		Email: "joshua@rubixconsulting.com",
	}}
	app.Before = setup
	app.Action = run
	app.Flags = []cli.Flag{
		cli.StringFlag{
			Name:   "import-prefix",
			EnvVar: "IMPORT_PREFIX",
			Usage:  "base url used for the vanity url, any part of the path after that given here is considered <package>",
		},
		cli.StringFlag{
			Name:   "vcs",
			EnvVar: "VCS",
			Value:  "git",
			Usage:  "vcs repo type",
		},
		cli.StringFlag{
			Name:   "repo-root",
			EnvVar: "REPO_ROOT",
			Usage:  "base url used for the repo package path, the first path part of <package> is appended",
		},
		cli.StringFlag{
			Name:   "redirect-url",
			EnvVar: "REDIRECT_URL",
			Usage:  "url to redirect browsers to, if empty, redirects to repo-root/package",
		},
		cli.StringFlag{
			Name:   "tls-listen-address",
			EnvVar: "TLS_LISTEN_ADDRESS",
			Value:  defaultTLSListenAddress,
			Usage:  "address (ip/hostname and port) that the server should listen on",
		},
		cli.StringFlag{
			Name:   "listen-address",
			EnvVar: "LISTEN_ADDRESS",
			Value:  defaultListenAddress,
			Usage:  "address (ip/hostname and port) that the server should listen on to redirect to the public tls address",
		},
		cli.StringFlag{
			Name:   "cache-file",
			EnvVar: "LETSENCRYPT_CACHE_FILE",
			Value:  "letsencrypt.cache",
			Usage:  "file to use as the letsencrypt cache",
		},
		cli.StringFlag{
			Name:   "email",
			EnvVar: "LETSENCRYPT_EMAIL",
			Usage:  "email address to use for registering with letsencrypt",
		},
		cli.StringFlag{
			Name:   "public-tls-address",
			EnvVar: "PUBLIC_TLS_ADDRESS",
			Usage:  "address (ip/hostname and optionally port) that the non-tls server should use when redirecting for https",
		},
		cli.BoolFlag{
			Name:   "no-tls",
			EnvVar: "NO_TLS",
			Usage:  "set this flag to disable tls support and listen only on \"listen-address\" without tls redirection",
		},
	}
}

func main() {
	if err := app.Run(os.Args); err != nil {
		log.Fatal(err)
	}
}

func setup(c *cli.Context) error {
	cfg = config{
		ImportPrefix:     c.String("import-prefix"),
		VCS:              c.String("vcs"),
		RepoRoot:         c.String("repo-root"),
		RedirectURL:      c.String("redirect-url"),
		ListenAddress:    c.String("listen-address"),
		TLSListenAddress: c.String("tls-listen-address"),
		PublicTLSAddress: c.String("public-tls-address"),
		TLS:              !c.Bool("no-tls"),
	}

	if cfg.TLS {
		if err := manager.CacheFile(c.String("cache-file")); err != nil {
			return err
		}

		if email := c.String("email"); len(email) > 0 {
			if err := manager.Register(email, nil); err != nil {
				return err
			}
		}
	}

	return nil
}

func run(c *cli.Context) error {
	if !cfg.TLS {
		log.Printf("listening for http at %s", cfg.ListenAddress)
		return http.ListenAndServe(cfg.ListenAddress, handler())
	}

	l, err := net.Listen("tcp", cfg.ListenAddress)
	if err != nil {
		return err
	}
	defer func() {
		if err := l.Close(); err != nil {
			log.Printf("error closing http listener: %v\n", err)
		}
	}()

	log.Printf("listening for http at %s", cfg.ListenAddress)
	go func() {
		if err := http.Serve(l, http.HandlerFunc(redirectHTTP)); err != nil {
			log.Printf("error starting http listener: %v\n", err)
		}
	}()

	return serveHTTPS()
}

func redirectHTTP(w http.ResponseWriter, r *http.Request) {
	if r.TLS != nil || r.Host == "" {
		http.Error(w, "not found", 404)
	}

	u := r.URL
	u.Host = cfg.PublicTLSAddress
	u.Scheme = "https"
	http.Redirect(w, r, u.String(), 302)
}

func serveHTTPS() error {
	srv := &http.Server{
		Addr: cfg.TLSListenAddress,
		TLSConfig: &tls.Config{
			GetCertificate: manager.GetCertificate,
		},
		Handler: handler(),
	}

	log.Printf("listening for tls at %s", cfg.TLSListenAddress)
	return srv.ListenAndServeTLS("", "")
}

func handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx := context{
			config:      cfg,
			RedirectURL: cfg.RedirectURL,
		}

		pkg := strings.Split(r.URL.Path, "/")
		if len(pkg) > 1 {
			ctx.RepoName = pkg[1]

			if len(cfg.RedirectURL) == 0 {
				ctx.RedirectURL = ctx.RepoRoot + "/" + pkg[1]
			}
		}

		w.Header().Set("Content-Type", "text/html; charset=utf-8")

		if err := html.ExecuteTemplate(w, htmlTplName, ctx); err != nil {
			log.Println("error executing template", err)
		}
	})
}
