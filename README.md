# 쌍극자 모멘트 방향 · 타임어택

결합의 극성과 쌍극자 모멘트 방향을 판단하는 단일 HTML 퀴즈 게임입니다.
두 가지 모드를 제공합니다.

- **📚 연습 모드** — 로그인 없이 랜덤 6문제 (기록 저장 안 됨)
- **🏆 랭킹 모드** — 닉네임 + 6자리 식별번호로 접속, 랜덤 8문제를 풀어 전국 랭킹에 등록

---

## 랭킹 시스템 개요

- **계정**: 닉네임(고유) + 6자리 식별번호(SHA-256 해시하여 저장)
- **순위 원칙**: 실수 횟수 적은 순 → 소요 시간 짧은 순
- **최고 기록 관리**: 한 사람당 1개 기록. 새 기록이 더 좋을 때만 갱신
- **랭킹보드**: TOP 10 명예의 전당 + 내 위치 ±3명 이웃 랭킹

---

## Supabase 설정 (랭킹 모드 활성화)

랭킹 모드를 쓰려면 Supabase 프로젝트를 한 번만 세팅하면 됩니다.

### 1. Supabase 프로젝트 만들기
1. [https://supabase.com](https://supabase.com) 접속 → 무료 계정 생성
2. **New Project** 클릭 → 이름·비밀번호·지역(Region: Northeast Asia – Seoul 추천) 입력 → 생성
3. 프로젝트가 준비될 때까지 1~2분 대기

### 2. 스키마 적용
1. 왼쪽 메뉴에서 **SQL Editor** 클릭
2. **+ New query** 버튼 클릭
3. 이 저장소의 `supabase-schema.sql` 파일 내용을 전부 복사해서 붙여넣기
4. **Run** 버튼 클릭 → 에러 없이 완료되면 OK

### 3. API 키 복사
1. 왼쪽 메뉴 **Project Settings** (톱니바퀴) → **API**
2. 다음 두 값을 복사:
   - **Project URL** (예: `https://abcd1234.supabase.co`)
   - **anon public** 키 (긴 JWT 문자열)

### 4. index.html에 키 입력
`index.html` 파일 상단의 아래 두 줄을 찾아 값을 바꿔 저장하세요.

```js
const SUPABASE_URL = "YOUR_SUPABASE_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

> 🔒 anon 키는 공개되어도 안전합니다. 모든 쓰기 작업은 RPC 함수 + RLS로 보호되어 있어, 키만으로는 랭킹 조작이 불가능합니다.

### 5. 배포
`index.html` 과 `supabase-schema.sql` 만 있으면 동작합니다.
GitHub Pages에서 이 저장소를 직접 호스팅하거나, Netlify/Vercel 등에도 바로 올릴 수 있습니다.

현재 배포 주소: <https://scieum.github.io/polarity-timeattack/>

---

## 데이터베이스 구조

- `quiz_users (id, nickname unique, pin_hash, created_at)`
- `quiz_rankings (user_id pk, nickname, mistakes, time_seconds, updated_at)`

### RPC 함수
| 함수 | 설명 |
|---|---|
| `register_user(nickname, pin_hash)` | 신규 등록 (중복 닉네임 거부) |
| `verify_user(nickname, pin_hash)` | 로그인 검증 |
| `nickname_exists(nickname)` | 닉네임 중복 사전 체크 |
| `submit_score(nickname, pin_hash, mistakes, time_seconds)` | 점수 제출 (더 좋은 경우만 갱신) |
| `get_top_ranking(limit)` | TOP N 리더보드 |
| `get_neighbors(nickname, window)` | 내 순위 + ±window 이웃 |

### RLS 정책
- `quiz_users`: RLS 활성화, 클라이언트 직접 접근 차단 (RPC만 사용)
- `quiz_rankings`: SELECT만 공개, 쓰기는 `submit_score` RPC를 통해서만 가능

### 순위 결정 규칙 (SQL)
```sql
ORDER BY mistakes ASC, time_seconds ASC, updated_at ASC
```

---

## 개인정보 관련 참고

- 저장되는 데이터: 닉네임(자기가 지정), 식별번호 해시, 기록(실수/시간/갱신시각)
- 실명·학교·연락처·이메일 등 일체 수집하지 않음
- 식별번호는 SHA-256으로 해시되어 저장되므로, 관리자도 원본을 알 수 없음
- 학교/학급에서 간단히 쓰기엔 충분하지만, 공개 서비스로 확장할 땐 개인정보처리방침 고지를 권장

---

## 로컬에서 실행

```bash
# 프로젝트 폴더에서 간단히 HTTP 서버 띄우기
python -m http.server 8000
```
→ http://localhost:8000 접속
