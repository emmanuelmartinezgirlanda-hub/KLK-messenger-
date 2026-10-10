package api

import (
	"log/slog"
	"net/http"
	"slices"
)

// Community es una comunidad por país de los dominicanos en el mundo.
type Community struct {
	ID   string `json:"id"`   // código del país (ISO 3166-1)
	Name string `json:"name"` // "República Dominicana", "España"…
	Flag string `json:"flag"` // emoji de la bandera
}

// Communities es la lista fija de países. RD va la primera.
var Communities = []Community{
	{"DO", "República Dominicana", "🇩🇴"},
	{"US", "Estados Unidos", "🇺🇸"},
	{"ES", "España", "🇪🇸"},
	{"PR", "Puerto Rico", "🇵🇷"},
	{"IT", "Italia", "🇮🇹"},
	{"CA", "Canadá", "🇨🇦"},
	{"IE", "Irlanda", "🇮🇪"},
	{"GB", "Reino Unido", "🇬🇧"},
	{"FR", "Francia", "🇫🇷"},
	{"DE", "Alemania", "🇩🇪"},
	{"CH", "Suiza", "🇨🇭"},
	{"NL", "Países Bajos", "🇳🇱"},
	{"BE", "Bélgica", "🇧🇪"},
	{"PT", "Portugal", "🇵🇹"},
	{"PA", "Panamá", "🇵🇦"},
	{"CO", "Colombia", "🇨🇴"},
	{"VE", "Venezuela", "🇻🇪"},
	{"MX", "México", "🇲🇽"},
	{"CL", "Chile", "🇨🇱"},
	{"AR", "Argentina", "🇦🇷"},
	{"CR", "Costa Rica", "🇨🇷"},
	{"HT", "Haití", "🇭🇹"},
	{"AW", "Aruba", "🇦🇼"},
	{"CW", "Curazao", "🇨🇼"},
}

// MaxCommunityMembers limita cuántos miembros se devuelven para enviar mensajes
// (los mensajes se cifran en el móvil para cada miembro).
const MaxCommunityMembers = 1000

func communityExists(id string) bool {
	return slices.ContainsFunc(Communities, func(c Community) bool { return c.ID == id })
}

type communityView struct {
	Community
	Members int  `json:"members"`
	Joined  bool `json:"joined"`
}

// GET /v1/communities: la lista con el número REAL de miembros y si ya estoy dentro.
func (s *Server) listCommunities(w http.ResponseWriter, r *http.Request) {
	dev := deviceFrom(r)
	counts, err := s.store.CommunityCounts(r.Context())
	if err != nil {
		slog.Error("comunidades", "err", err)
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	mine, err := s.store.CommunitiesOf(r.Context(), dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	out := make([]communityView, 0, len(Communities))
	for _, c := range Communities {
		out = append(out, communityView{Community: c, Members: counts[c.ID], Joined: slices.Contains(mine, c.ID)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"communities": out})
}

// POST /v1/communities/{id}: unirme.  DELETE: salirme.
func (s *Server) joinCommunity(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !communityExists(id) {
		writeErr(w, http.StatusNotFound, "not_found", "esa comunidad no existe")
		return
	}
	dev := deviceFrom(r)
	var err error
	if r.Method == http.MethodDelete {
		err = s.store.LeaveCommunity(r.Context(), id, dev.AccountID)
	} else {
		err = s.store.JoinCommunity(r.Context(), id, dev.AccountID)
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// GET /v1/communities/{id}/members: ids de los miembros, solo para quien está dentro.
// No se devuelven números de teléfono.
func (s *Server) communityMembers(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !communityExists(id) {
		writeErr(w, http.StatusNotFound, "not_found", "esa comunidad no existe")
		return
	}
	dev := deviceFrom(r)
	mine, err := s.store.CommunitiesOf(r.Context(), dev.AccountID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	if !slices.Contains(mine, id) {
		writeErr(w, http.StatusForbidden, "not_member", "únete primero a la comunidad")
		return
	}
	members, err := s.store.CommunityMembers(r.Context(), id, MaxCommunityMembers)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "error interno")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"members": members})
}
