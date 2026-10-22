package api

import (
	"sync"
	"time"
)

// dailyQuota cuenta cuánto gasta cada cuenta en un día (en memoria: se
// reinicia con el servidor, que es suficiente para frenar abusos).
type dailyQuota struct {
	mu   sync.Mutex
	day  string
	used map[string]int64
}

// take suma n a la cuenta si no pasa de max. Devuelve false si ya no cabe.
func (q *dailyQuota) take(acc string, n, max int64, now time.Time) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	day := now.UTC().Format("2006-01-02")
	if q.day != day || q.used == nil {
		q.day, q.used = day, map[string]int64{}
	}
	if q.used[acc]+n > max {
		return false
	}
	q.used[acc] += n
	return true
}

// Límites diarios por cuenta. Un uso normal no se acerca a ellos; frenan a
// quien intente descubrir qué números usan KLK, gastar las claves de otros
// o llenar el almacén de archivos.
const (
	maxLookupsPerDay     = 20000   // números comprobados (agenda incluida)
	maxBundlesPerDay     = 400     // claves pedidas para empezar chats cifrados
	maxUploadsPerDay     = 600     // archivos subidos
	maxUploadBytesPerDay = 3 << 30 // 3 GB subidos
)
