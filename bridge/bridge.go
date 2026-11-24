// RedX read-only adapter for the upstream Apache-2.0 Go library.
package redbridge

import (
 "context"
 "encoding/json"
 "sync"
 "time"
 xhs "github.com/tamnd/xiaohongshu-cli/xiaohongshu"
)

var mu sync.Mutex
var client *xhs.Client

func getClient() *xhs.Client {
 if client == nil {
  cfg := xhs.DefaultConfig()
  cfg.Cookie = ""
  cfg.NoCache = true
  cfg.Rate = 1500*time.Millisecond
  cfg.Timeout = 15*time.Second
  client = xhs.NewClient(cfg)
 }
 return client
}

func encode(data any, err error) string {
 out := map[string]any{"data":data}
 if err != nil { out["error"] = err.Error() }
 b,e:=json.Marshal(out)
 if e!=nil { return "{\"error\":\"JSON encode failed\"}" }
 return string(b)
}

func Feed(limit int) string {
 mu.Lock(); defer mu.Unlock()
 if limit < 1 || limit > 30 { limit = 20 }
 ctx,cancel:=context.WithTimeout(context.Background(),45*time.Second); defer cancel()
 items:=make([]xhs.FeedItem,0,limit)
 for item,err:=range getClient().Feed(ctx,"recommend",limit) {
  if err!=nil { return encode(items,err) }
  items=append(items,item)
 }
 return encode(items,nil)
}

func Note(id,token string) string {
 mu.Lock(); defer mu.Unlock()
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second); defer cancel()
 n,err:=getClient().Note(ctx,id,token)
 if err!=nil { return encode(nil,err) }
 return encode(n,nil)
}
