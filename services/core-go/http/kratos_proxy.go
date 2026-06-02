package http

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
)

const kratosProxyPrefix = "/auth/kratos"

// WrapWithKratosProxy forwards `/auth/kratos/*` to the Kratos public API so
// browser clients (Flutter web) share core-go's origin and inherit its CORS
// middleware. Native clients may still talk to Kratos directly.
func WrapWithKratosProxy(kratosPublicURL string, next http.Handler) http.Handler {
	target, err := url.Parse(strings.TrimRight(kratosPublicURL, "/"))
	if err != nil || target.Scheme == "" || target.Host == "" {
		return next
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Host = target.Host
		stripped := strings.TrimPrefix(req.URL.Path, kratosProxyPrefix)
		if stripped == "" {
			stripped = "/"
		}
		req.URL.Path = stripped
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		// core-go's CORSMiddleware owns Access-Control-* headers. Kratos may
		// also emit them; strip upstream values to avoid duplicate headers.
		resp.Header.Del("Access-Control-Allow-Origin")
		resp.Header.Del("Access-Control-Allow-Credentials")
		resp.Header.Del("Access-Control-Allow-Methods")
		resp.Header.Del("Access-Control-Allow-Headers")
		resp.Header.Del("Access-Control-Expose-Headers")
		resp.Header.Del("Access-Control-Max-Age")
		return nil
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == kratosProxyPrefix || strings.HasPrefix(r.URL.Path, kratosProxyPrefix+"/") {
			proxy.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}
