# Phase 1 상세 구현 가이드: 기본 인프라 구축

> **목표**: 실시간 채팅 시스템의 핵심 인프라를 구축합니다.
> **예상 소요 시간**: 1-2일
> **난이도**: ⭐⭐⭐ (중급)

---

## 📚 목차

1. [Phase 1 전체 개요](#phase-1-전체-개요)
2. [JMS와 ActiveMQ Artemis](#1-jms와-activemq-artemis)
3. [인메모리 저장소](#2-인메모리-저장소)
4. [JWT 인증 시스템](#3-jwt-인증-시스템)
5. [Spring Security 설정](#4-spring-security-설정)
6. [구현 순서](#5-구현-순서)
7. [테스트 방법](#6-테스트-방법)

---

## Phase 1 전체 개요

### 🎯 왜 Phase 1이 필요한가?

현재 우리의 채팅 앱은 기본적인 WebSocket만 있는 상태입니다.
하지만 **실제 서비스**로 만들기 위해서는 다음 문제들을 해결해야 합니다:

| 문제 상황 | 현재 상태 | Phase 1 완료 후 |
|----------|----------|---------------|
| 💥 메시지 유실 | WebSocket 연결이 끊기면 메시지 손실 | JMS 큐로 안전하게 보관 |
| 🔓 보안 취약 | 누구나 접속 가능 | JWT 토큰 기반 인증 |
| 💾 데이터 휘발 | 서버 재시작 시 접속자 정보 소실 | 인메모리 저장소로 관리 |
| 👤 사용자 관리 | 사용자 상태 추적 불가 | 온라인/오프라인 상태 관리 |

### 🏗️ Phase 1 아키텍처 구조

```
┌──────────────────────────────────────────────────────────┐
│                     클라이언트 (브라우저)                   │
│                                                            │
│  1. 로그인 요청 → JWT 토큰 받음                            │
│  2. 이후 모든 요청에 JWT 토큰 포함                         │
└─────────────────────┬──────────────────────────────────────┘
                      │
                      │ HTTP + JWT Token
                      │
                      ▼
┌──────────────────────────────────────────────────────────┐
│              Spring Security Filter Chain                 │
│                                                            │
│  ┌─────────────────────────────────────┐                 │
│  │  JwtAuthenticationFilter            │                 │
│  │  - 토큰 검증                         │                 │
│  │  - 사용자 인증                       │                 │
│  └─────────────────────────────────────┘                 │
└─────────────────────┬──────────────────────────────────────┘
                      │
                      │ 인증 성공
                      │
                      ▼
┌──────────────────────────────────────────────────────────┐
│                  Spring Boot Application                  │
│                                                            │
│  ┌─────────────────┐   ┌─────────────────┐              │
│  │  Controller     │   │  Service        │              │
│  │  (메시지 수신)   │──▶│  (비즈니스 로직) │              │
│  └─────────────────┘   └────────┬────────┘              │
│                                  │                        │
│                                  ▼                        │
│                     ┌─────────────────────┐              │
│                     │  MessageProducer    │              │
│                     │  (JMS 발행)          │              │
│                     └──────────┬──────────┘              │
└────────────────────────────────┼──────────────────────────┘
                                 │
                                 │ JMS Send
                                 │
                                 ▼
                   ┌────────────────────────┐
                   │  ActiveMQ Artemis     │
                   │  (메시지 큐)           │
                   │                        │
                   │  📦 chat.messages     │
                   │  📦 user.presence     │
                   └──────────┬─────────────┘
                              │
                              │ JMS Listener
                              │
                              ▼
                   ┌────────────────────────┐
                   │  MessageConsumer      │
                   │  - DB 저장            │
                   │  - 캐시 업데이트       │
                   │  - WebSocket 전송     │
                   └────────────────────────┘
                              │
                              ├─────▶ 💾 Database
                              │
                              ├─────▶ 🗂️ In-Memory Cache
                              │         - UserSessionStore
                              │         - ChannelSubscriptionStore
                              │         - MessageCacheStore
                              │
                              └─────▶ 📡 WebSocket (실시간 전송)
```

---

## 1. JMS와 ActiveMQ Artemis

### 1.1 JMS란 무엇인가?

**JMS (Java Message Service)**는 Java 애플리케이션에서 **메시지를 주고받기 위한 표준 API**입니다.

#### 💡 실생활 비유

```
JMS = 우체국 시스템

[발신자] → [우체국 집배함] → [수신자]
   ↓             ↓              ↓
Producer    Message Queue    Consumer

- 발신자는 우편함에 편지를 넣기만 하면 됨 (비동기)
- 수신자가 집에 없어도 편지는 우편함에 안전하게 보관됨
- 수신자는 나중에 와서 편지를 가져갈 수 있음
```

### 1.2 왜 WebSocket만으로는 부족한가?

| WebSocket 만 사용 | WebSocket + JMS 조합 |
|------------------|---------------------|
| ❌ 연결 끊김 = 메시지 손실 | ✅ 큐에 저장되어 안전 |
| ❌ 서버 재시작 시 메시지 사라짐 | ✅ 영구 저장 가능 |
| ❌ 대량 메시지 처리 시 부하 | ✅ 큐에서 순차 처리 |
| ❌ 장애 복구 어려움 | ✅ 재시도 메커니즘 |

#### 예시 시나리오: 메시지 유실 방지

```kotlin
// ❌ 나쁜 예: WebSocket만 사용
@MessageMapping("/chat/send")
fun sendMessage(message: ChatMessageDTO) {
    // 직접 WebSocket으로 전송
    messagingTemplate.convertAndSend("/topic/chat", message)
    // 문제: 만약 이 순간 네트워크 끊기면 메시지 손실!
}

// ✅ 좋은 예: JMS 사용
@MessageMapping("/chat/send")
fun sendMessage(message: ChatMessageDTO) {
    // 먼저 JMS 큐에 저장 (안전하게 보관)
    messageProducer.sendChatMessage(message)
    // JMS Consumer가 나중에 안전하게 처리
}
```

### 1.3 ActiveMQ Artemis란?

**ActiveMQ Artemis**는 JMS 스펙을 구현한 **메시지 브로커(Message Broker)**입니다.

```
[메시지 브로커의 역할]

Producer               Artemis Broker                Consumer
  │                         │                           │
  │ 1. 메시지 발행          │                           │
  ├────────────────────────▶│                           │
  │                         │ [Queue에 저장]            │
  │                         │   📦 Message 1           │
  │                         │   📦 Message 2           │
  │                         │   📦 Message 3           │
  │ 2. 발행 완료 응답       │                           │
  │◀────────────────────────┤                           │
  │                         │                           │
  │                         │ 3. 메시지 요청            │
  │                         │◀──────────────────────────┤
  │                         │                           │
  │                         │ 4. 메시지 전달            │
  │                         ├───────────────────────────▶│
  │                         │                           │
  │                         │ 5. 처리 완료 ACK          │
  │                         │◀──────────────────────────┤
  │                         │ [Queue에서 제거]          │
```

### 1.4 구현 코드 상세 설명

#### Step 1: build.gradle에 의존성 추가

```gradle
dependencies {
    // JMS 스타터: Spring Boot의 JMS 지원 기능
    implementation 'org.springframework.boot:spring-boot-starter-artemis'

    // Artemis 서버: 임베디드 브로커 (개발/테스트용)
    implementation 'org.apache.activemq:artemis-jakarta-server:2.31.0'

    // Artemis 클라이언트: 메시지 송수신 클라이언트
    implementation 'org.apache.activemq:artemis-jakarta-client:2.31.0'
}
```

**왜 세 개나 필요한가?**
- `starter-artemis`: Spring과 Artemis 연동 설정
- `artemis-jakarta-server`: 메시지 브로커 (우체국 건물)
- `artemis-jakarta-client`: 메시지 송수신 (우편 서비스 이용자)

#### Step 2: JMS 설정 클래스

**파일**: `src/main/kotlin/net/meeemo/chat/config/JmsConfig.kt`

```kotlin
package net.meeemo.chat.config

import org.apache.activemq.artemis.core.config.impl.ConfigurationImpl
import org.apache.activemq.artemis.core.server.embedded.EmbeddedActiveMQ
import org.apache.activemq.artemis.core.settings.impl.AddressSettings
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.jms.annotation.EnableJms

/**
 * JMS (Java Message Service) 설정 클래스
 *
 * 목적: ActiveMQ Artemis 메시지 브로커를 임베디드 모드로 실행
 *
 * 왜 임베디드 모드?
 * - 개발 단계: 별도 서버 설치 없이 애플리케이션과 함께 실행
 * - 프로덕션: 별도 Artemis 서버 사용 (application-prod.yml에서 설정)
 */
@Configuration
@EnableJms  // Spring JMS 기능 활성화
class JmsConfig {

    /**
     * Artemis 브로커 설정
     *
     * 설정 옵션 설명:
     * - isPersistenceEnabled: 메시지를 디스크에 저장할지 여부
     *   → false: 메모리에만 저장 (빠르지만 재시작 시 손실)
     *   → true: 디스크에 저장 (느리지만 안전)
     *
     * - isSecurityEnabled: 인증/인가 사용 여부
     *   → false: 개발 편의성 (누구나 접근)
     *   → true: 프로덕션 권장 (사용자명/비밀번호 필요)
     */
    @Bean
    fun artemisConfiguration(): org.apache.activemq.artemis.core.config.Configuration {
        return ConfigurationImpl().apply {
            // 개발 환경 설정
            isPersistenceEnabled = false  // 인메모리 모드
            isSecurityEnabled = false     // 보안 비활성화

            // 내부 통신 프로토콜 설정
            addAcceptorConfiguration("in-vm", "vm://0")

            // 큐 생성: chat.messages
            addAddressConfiguration(
                org.apache.activemq.artemis.core.config.CoreAddressConfiguration()
                    .setName("chat.messages")
                    .addRoutingType(org.apache.activemq.artemis.api.core.RoutingType.ANYCAST)
                    .addQueueConfiguration(
                        org.apache.activemq.artemis.core.config.impl.QueueConfiguration("chat.messages")
                            .setRoutingType(org.apache.activemq.artemis.api.core.RoutingType.ANYCAST)
                            .setDurable(false)  // 재시작 시 큐 유지 안 함
                    )
            )

            // 큐 생성: user.presence (사용자 상태 변경)
            addAddressConfiguration(
                org.apache.activemq.artemis.core.config.CoreAddressConfiguration()
                    .setName("user.presence")
                    .addRoutingType(org.apache.activemq.artemis.api.core.RoutingType.ANYCAST)
                    .addQueueConfiguration(
                        org.apache.activemq.artemis.core.config.impl.QueueConfiguration("user.presence")
                            .setRoutingType(org.apache.activemq.artemis.api.core.RoutingType.ANYCAST)
                            .setDurable(false)
                    )
            )

            // Address 설정 (메시지 라우팅 규칙)
            addressSettings["#"] = AddressSettings().apply {
                maxSizeBytes = 10_000_000  // 큐 최대 크기: 10MB
                maxDeliveryAttempts = 3    // 최대 재시도 횟수
                redeliveryDelay = 1000L    // 재시도 간격: 1초
            }
        }
    }

    /**
     * 임베디드 Artemis 서버 빈
     *
     * Spring 컨테이너 시작 시 자동으로 Artemis 서버 시작
     * 애플리케이션 종료 시 자동으로 서버 종료
     */
    @Bean(initMethod = "start", destroyMethod = "stop")
    fun embeddedActiveMQ(configuration: org.apache.activemq.artemis.core.config.Configuration): EmbeddedActiveMQ {
        return EmbeddedActiveMQ().apply {
            setConfiguration(configuration)
        }
    }
}
```

#### 핵심 개념: Routing Type

```
[ANYCAST vs MULTICAST]

📮 ANYCAST (Point-to-Point)
Producer → [Queue] → Consumer 1
            (하나만 받음)

- 메시지를 딱 1명의 Consumer만 받음
- 채팅 메시지 처리에 적합 (중복 처리 방지)

📡 MULTICAST (Pub-Sub)
Producer → [Topic] → Consumer 1
                   → Consumer 2
                   → Consumer 3
           (모두 받음)

- 모든 구독자가 메시지를 받음
- 브로드캐스트에 적합
```

**우리의 선택**: ANYCAST
- 이유: 메시지를 DB에 한 번만 저장하고, WebSocket으로 한 번만 전송

---

## 2. 인메모리 저장소

### 2.1 왜 DB만으로는 부족한가?

```
시나리오: 사용자가 채팅방에 입장

❌ DB만 사용
1. 사용자 A 입장
2. DB 조회: "채팅방 1의 접속자는?"
   → Query 실행 (느림, 부하)
3. 응답: [사용자 B, 사용자 C]

✅ 인메모리 저장소 사용
1. 사용자 A 입장
2. 메모리 조회: userSessionStore.getActiveUsers()
   → 즉시 반환 (빠름, 가벼움)
3. 응답: [사용자 B, 사용자 C]

속도 비교: 메모리 조회 (< 1ms) vs DB 조회 (10-100ms)
```

### 2.2 세 가지 저장소의 역할

| 저장소 | 용도 | 예시 데이터 |
|-------|------|-----------|
| **UserSessionStore** | 접속 중인 사용자 세션 | { sessionId: "abc123", userId: "1", status: "ONLINE" } |
| **ChannelSubscriptionStore** | 채널 구독 관계 | { channelId: "1", subscribers: ["session1", "session2"] } |
| **MessageCacheStore** | 최근 메시지 캐시 | 채널별 최근 100개 메시지 |

### 2.3 구현 코드: UserSessionStore

**파일**: `src/main/kotlin/net/meeemo/chat/store/UserSessionStore.kt`

```kotlin
package net.meeemo.chat.store

import org.springframework.stereotype.Component
import java.time.LocalDateTime
import java.util.concurrent.ConcurrentHashMap

/**
 * 사용자 세션 인메모리 저장소
 *
 * 목적:
 * 1. 현재 접속 중인 사용자 추적
 * 2. 사용자 온라인/오프라인 상태 관리
 * 3. 워크스페이스별 활성 사용자 조회
 *
 * 왜 ConcurrentHashMap?
 * - 멀티스레드 환경에서 안전하게 동작
 * - 여러 사용자가 동시에 접속/종료할 때 데이터 일관성 보장
 */
@Component
class UserSessionStore {

    /**
     * sessionId → UserSession 매핑
     *
     * sessionId: WebSocket 연결마다 생성되는 고유 ID
     * - 같은 사용자도 브라우저 창을 2개 열면 sessionId 2개
     */
    private val sessions = ConcurrentHashMap<String, UserSession>()

    /**
     * 사용자 세션 데이터 클래스
     *
     * @property userId 사용자 DB ID
     * @property username 사용자 이름 (화면 표시용)
     * @property email 이메일 주소
     * @property sessionId WebSocket 세션 ID
     * @property workspaceId 현재 접속 중인 워크스페이스
     * @property status 사용자 상태 (온라인/자리비움/오프라인)
     * @property lastActive 마지막 활동 시간 (자동 로그아웃용)
     */
    data class UserSession(
        val userId: String,
        val username: String,
        val email: String,
        val sessionId: String,
        val workspaceId: String,
        val status: UserStatus = UserStatus.ONLINE,
        val lastActive: LocalDateTime = LocalDateTime.now()
    )

    /**
     * 사용자 상태 열거형
     *
     * Slack과 동일한 상태 시스템
     */
    enum class UserStatus {
        ONLINE,   // 🟢 온라인
        AWAY,     // 🟡 자리비움
        OFFLINE   // ⚪ 오프라인
    }

    /**
     * 새로운 세션 추가
     *
     * 호출 시점: 사용자가 WebSocket 연결할 때
     *
     * 예시:
     * ```
     * val session = UserSession(
     *     userId = "1",
     *     username = "홍길동",
     *     email = "hong@example.com",
     *     sessionId = "abc123",
     *     workspaceId = "workspace-1"
     * )
     * userSessionStore.addSession(session)
     * ```
     */
    fun addSession(session: UserSession) {
        sessions[session.sessionId] = session
        println("✅ 사용자 세션 추가: ${session.username} (${session.sessionId})")
    }

    /**
     * 세션 제거
     *
     * 호출 시점: WebSocket 연결 종료 시
     *
     * 주의: 같은 사용자가 다른 브라우저에서 접속 중일 수 있음
     */
    fun removeSession(sessionId: String) {
        val session = sessions.remove(sessionId)
        if (session != null) {
            println("❌ 사용자 세션 제거: ${session.username} (${sessionId})")
        }
    }

    /**
     * 세션 조회
     *
     * 용도: 메시지 전송 시 발신자 정보 확인
     */
    fun getSession(sessionId: String): UserSession? {
        return sessions[sessionId]
    }

    /**
     * 워크스페이스의 활성 사용자 목록
     *
     * 용도:
     * - 사이드바에 "현재 접속 중인 멤버" 표시
     * - 새 사용자 입장 시 기존 멤버들에게 알림
     *
     * @return 온라인 상태인 사용자만 반환
     */
    fun getActiveUsers(workspaceId: String): List<UserSession> {
        return sessions.values
            .filter {
                it.workspaceId == workspaceId &&
                it.status == UserStatus.ONLINE
            }
    }

    /**
     * 사용자 상태 업데이트
     *
     * 시나리오:
     * 1. 사용자가 상태 셀렉트박스에서 "자리비움" 선택
     * 2. 프론트엔드 → API 호출
     * 3. 이 메서드 실행
     * 4. JMS로 상태 변경 이벤트 발행
     * 5. 같은 워크스페이스의 모든 사용자에게 WebSocket으로 전파
     */
    fun updateStatus(sessionId: String, status: UserStatus) {
        sessions[sessionId]?.let { oldSession ->
            // Kotlin의 data class copy() 사용
            // - 불변성 유지 (새로운 객체 생성)
            sessions[sessionId] = oldSession.copy(
                status = status,
                lastActive = LocalDateTime.now()
            )
            println("🔄 상태 변경: ${oldSession.username} → $status")
        }
    }

    /**
     * 전체 세션 수 (디버깅/모니터링용)
     */
    fun getTotalSessions(): Int = sessions.size

    /**
     * 특정 사용자의 모든 세션 (다중 브라우저 탭)
     *
     * 용도: 사용자가 여러 창을 열었는지 확인
     */
    fun getSessionsByUserId(userId: String): List<UserSession> {
        return sessions.values.filter { it.userId == userId }
    }

    /**
     * 비활성 세션 정리 (스케줄러에서 주기적 호출)
     *
     * 목적: 메모리 누수 방지
     * - WebSocket 연결은 끊겼지만 세션이 남아있는 경우
     * - 마지막 활동 시간이 30분 이상 지난 경우
     */
    fun cleanupInactiveSessions(inactiveThresholdMinutes: Long = 30) {
        val now = LocalDateTime.now()
        val removed = sessions.entries.removeIf { (_, session) ->
            session.lastActive.plusMinutes(inactiveThresholdMinutes).isBefore(now)
        }
        if (removed) {
            println("🧹 비활성 세션 정리 완료")
        }
    }
}
```

### 2.4 동작 흐름 예시

```
[사용자 A가 접속하는 과정]

1. 브라우저: WebSocket 연결 시도
   ws://localhost:8080/api/ws

2. Spring: WebSocket 연결 성공
   → sessionId 생성: "abc123xyz"

3. WebSocketEventListener: SessionConnectedEvent 감지
   @EventListener
   fun handleConnect(event: SessionConnectedEvent) {
       val sessionId = event.sessionId
       val user = getCurrentUser()  // JWT에서 추출

       // 세션 저장소에 추가
       userSessionStore.addSession(UserSession(
           userId = user.id,
           username = user.name,
           email = user.email,
           sessionId = sessionId,
           workspaceId = getCurrentWorkspace(),
           status = ONLINE
       ))
   }

4. 메모리 상태:
   sessions = {
       "abc123xyz" → UserSession(userId="1", username="홍길동", ...)
   }

5. 다른 사용자들에게 알림:
   "홍길동님이 입장하셨습니다"
```

---

## 3. JWT 인증 시스템

### 3.1 JWT란 무엇인가?

**JWT (JSON Web Token)**: 사용자 정보를 안전하게 전달하는 토큰 방식

#### 전통적인 세션 방식 vs JWT

```
[세션 방식]
1. 로그인 → 서버가 세션 ID 생성
2. 세션 ID를 쿠키에 저장
3. 매 요청마다 세션 ID 전송
4. 서버가 세션 저장소에서 사용자 정보 조회

문제점:
❌ 서버 메모리 사용 (세션 저장)
❌ 서버 여러 대 사용 시 세션 공유 어려움
❌ 모바일 앱에서 쿠키 사용 불편

[JWT 방식]
1. 로그인 → 서버가 JWT 토큰 생성
2. JWT를 클라이언트에 전달 (로컬스토리지 저장)
3. 매 요청마다 JWT를 Authorization 헤더에 포함
4. 서버가 JWT 서명 검증만 하면 끝 (DB 조회 불필요)

장점:
✅ 서버가 상태를 저장하지 않음 (Stateless)
✅ 확장성 좋음 (서버 여러 대 가능)
✅ 모바일/웹 모두 사용 가능
```

### 3.2 JWT 구조

```
JWT = Header.Payload.Signature

예시:
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.
eyJzdWIiOiIxIiwiZW1haWwiOiJob25nQGV4YW1wbGUuY29tIiwiaWF0IjoxNTE2MjM5MDIyfQ.
SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c

[Header] - 토큰 메타데이터
{
  "alg": "HS256",    // 서명 알고리즘
  "typ": "JWT"       // 토큰 타입
}

[Payload] - 사용자 정보 (Claims)
{
  "sub": "1",                           // 사용자 ID
  "email": "hong@example.com",          // 이메일
  "workspaceId": "workspace-1",         // 워크스페이스
  "iat": 1516239022,                    // 발행 시간
  "exp": 1516325422                     // 만료 시간
}

[Signature] - 위변조 방지 서명
HMACSHA256(
  base64UrlEncode(header) + "." +
  base64UrlEncode(payload),
  secret_key  // 서버만 아는 비밀 키
)
```

### 3.3 보안 원리

```
[공격자가 JWT를 변조하려고 시도]

원본 JWT:
{
  "sub": "1",
  "email": "user@example.com",
  "role": "USER"
}

변조 시도:
{
  "sub": "1",
  "email": "user@example.com",
  "role": "ADMIN"  // ← 권한 상승 시도
}

결과:
❌ 서명 검증 실패!

왜?
- Payload가 변경되면 Signature도 달라져야 함
- 하지만 secret_key를 모르면 올바른 Signature 생성 불가
- 서버가 검증 시 변조 탐지
```

### 3.4 구현 코드: JwtTokenProvider

**파일**: `src/main/kotlin/net/meeemo/chat/security/JwtTokenProvider.kt`

```kotlin
package net.meeemo.chat.security

import io.jsonwebtoken.*
import io.jsonwebtoken.security.Keys
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Component
import java.security.Key
import java.util.*

/**
 * JWT 토큰 생성 및 검증 유틸리티
 *
 * 역할:
 * 1. 로그인 성공 시 JWT 토큰 생성
 * 2. API 요청 시 JWT 토큰 검증
 * 3. 토큰에서 사용자 정보 추출
 */
@Component
class JwtTokenProvider {

    /**
     * JWT 서명에 사용할 비밀 키
     *
     * application.yml에서 주입:
     * jwt:
     *   secret: your-256-bit-secret-key-change-in-production
     *
     * ⚠️ 보안 주의사항:
     * - 최소 256비트 (32자 이상)
     * - 프로덕션에서는 환경 변수로 관리
     * - Git에 커밋하지 말 것
     */
    @Value("\${jwt.secret}")
    private lateinit var secretKey: String

    /**
     * 토큰 만료 시간 (밀리초)
     *
     * 기본값: 86400000ms = 24시간
     *
     * 고려사항:
     * - 너무 길면: 보안 위험 (토큰 탈취 시 오래 사용 가능)
     * - 너무 짧으면: 사용자 경험 나쁨 (자주 로그인)
     * - 추천: 1-7일
     */
    @Value("\${jwt.expiration:86400000}")
    private var expiration: Long = 86400000

    /**
     * HMAC-SHA256 서명 키 생성
     *
     * lazy: 처음 사용할 때만 생성 (성능 최적화)
     */
    private val key: Key by lazy {
        Keys.hmacShaKeyFor(secretKey.toByteArray())
    }

    /**
     * JWT 토큰 생성
     *
     * @param userId 사용자 ID (subject)
     * @param email 이메일 (custom claim)
     * @param workspaceId 워크스페이스 ID (custom claim)
     * @return JWT 토큰 문자열
     *
     * 호출 예시:
     * ```
     * val token = jwtTokenProvider.generateToken(
     *     userId = "1",
     *     email = "hong@example.com",
     *     workspaceId = "workspace-1"
     * )
     * // 결과: "eyJhbGciOiJIUzI1NiIs..."
     * ```
     */
    fun generateToken(userId: String, email: String, workspaceId: String): String {
        val now = Date()
        val expiryDate = Date(now.time + expiration)

        return Jwts.builder()
            // subject: JWT 표준 클레임 (주체)
            .setSubject(userId)

            // custom claims: 우리가 필요한 추가 정보
            .claim("email", email)
            .claim("workspaceId", workspaceId)

            // 발행 시간
            .setIssuedAt(now)

            // 만료 시간
            .setExpiration(expiryDate)

            // 서명 (HMAC-SHA256)
            .signWith(key, SignatureAlgorithm.HS256)

            // 문자열로 변환
            .compact()
    }

    /**
     * JWT 토큰 검증
     *
     * 검증 항목:
     * 1. 서명 유효성 (위변조 확인)
     * 2. 만료 시간
     * 3. 형식 올바른지
     *
     * @return true: 유효한 토큰 / false: 무효한 토큰
     *
     * 예외 처리:
     * - ExpiredJwtException: 만료된 토큰
     * - UnsupportedJwtException: 지원하지 않는 형식
     * - MalformedJwtException: 손상된 토큰
     * - SignatureException: 서명 검증 실패
     * - IllegalArgumentException: 빈 토큰
     */
    fun validateToken(token: String): Boolean {
        return try {
            Jwts.parserBuilder()
                .setSigningKey(key)  // 서명 검증 키 설정
                .build()
                .parseClaimsJws(token)  // 파싱 + 검증

            // 예외 없이 여기까지 도달 = 유효한 토큰
            true

        } catch (ex: ExpiredJwtException) {
            println("⏰ 만료된 JWT 토큰: ${ex.message}")
            false
        } catch (ex: UnsupportedJwtException) {
            println("❌ 지원하지 않는 JWT 토큰: ${ex.message}")
            false
        } catch (ex: MalformedJwtException) {
            println("❌ 손상된 JWT 토큰: ${ex.message}")
            false
        } catch (ex: SignatureException) {
            println("❌ 서명 검증 실패: ${ex.message}")
            false
        } catch (ex: IllegalArgumentException) {
            println("❌ 빈 JWT 토큰: ${ex.message}")
            false
        }
    }

    /**
     * 토큰에서 사용자 ID 추출
     *
     * @param token JWT 토큰
     * @return 사용자 ID (subject claim)
     */
    fun getUserIdFromToken(token: String): String {
        return getClaims(token).subject
    }

    /**
     * 토큰에서 이메일 추출
     */
    fun getEmailFromToken(token: String): String {
        return getClaims(token)["email"] as String
    }

    /**
     * 토큰에서 워크스페이스 ID 추출
     */
    fun getWorkspaceIdFromToken(token: String): String {
        return getClaims(token)["workspaceId"] as String
    }

    /**
     * 토큰에서 모든 Claims 추출
     *
     * Claims: JWT Payload에 포함된 모든 정보
     */
    fun getClaims(token: String): Claims {
        return Jwts.parserBuilder()
            .setSigningKey(key)
            .build()
            .parseClaimsJws(token)
            .body
    }

    /**
     * 토큰 만료 여부 확인
     *
     * @return true: 만료됨 / false: 유효함
     */
    fun isTokenExpired(token: String): Boolean {
        return try {
            val expiration = getClaims(token).expiration
            expiration.before(Date())
        } catch (e: Exception) {
            true
        }
    }

    /**
     * 토큰 남은 유효 시간 (초)
     *
     * 용도: "토큰이 5분 후 만료됩니다" 알림
     */
    fun getTokenRemainingTime(token: String): Long {
        return try {
            val expiration = getClaims(token).expiration
            val now = Date()
            (expiration.time - now.time) / 1000  // 밀리초 → 초
        } catch (e: Exception) {
            0
        }
    }
}
```

### 3.5 인증 필터: JwtAuthenticationFilter

**파일**: `src/main/kotlin/net/meeemo/chat/security/JwtAuthenticationFilter.kt`

```kotlin
package net.meeemo.chat.security

import jakarta.servlet.FilterChain
import jakarta.servlet.http.HttpServletRequest
import jakarta.servlet.http.HttpServletResponse
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken
import org.springframework.security.core.context.SecurityContextHolder
import org.springframework.stereotype.Component
import org.springframework.web.filter.OncePerRequestFilter

/**
 * JWT 인증 필터
 *
 * Spring Security Filter Chain에 추가되어
 * 모든 HTTP 요청을 가로채서 JWT 토큰을 검증합니다.
 *
 * 동작 순서:
 * 1. HTTP 요청 도착
 * 2. Authorization 헤더에서 JWT 추출
 * 3. JWT 검증
 * 4. 유효하면 SecurityContext에 인증 정보 저장
 * 5. 다음 필터로 진행
 *
 * OncePerRequestFilter: 요청당 한 번만 실행 보장
 */
@Component
class JwtAuthenticationFilter(
    private val jwtTokenProvider: JwtTokenProvider
) : OncePerRequestFilter() {

    /**
     * 필터 메인 로직
     *
     * @param request HTTP 요청
     * @param response HTTP 응답
     * @param filterChain 다음 필터로 진행
     */
    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        try {
            // 1. Authorization 헤더에서 JWT 추출
            val jwt = extractJwtFromRequest(request)

            // 2. JWT가 있고 유효한 경우
            if (jwt != null && jwtTokenProvider.validateToken(jwt)) {
                // 3. 토큰에서 사용자 정보 추출
                val userId = jwtTokenProvider.getUserIdFromToken(jwt)
                val email = jwtTokenProvider.getEmailFromToken(jwt)
                val workspaceId = jwtTokenProvider.getWorkspaceIdFromToken(jwt)

                // 4. Spring Security 인증 객체 생성
                val authentication = UsernamePasswordAuthenticationToken(
                    userId,  // principal: 인증된 사용자 (주체)
                    null,    // credentials: 비밀번호 (JWT 방식에서는 불필요)
                    emptyList()  // authorities: 권한 목록 (추후 ROLE 추가 가능)
                )

                // 5. 추가 정보를 details에 저장
                authentication.details = mapOf(
                    "email" to email,
                    "workspaceId" to workspaceId
                )

                // 6. SecurityContext에 인증 정보 저장
                // → Controller에서 @AuthenticationPrincipal로 접근 가능
                SecurityContextHolder.getContext().authentication = authentication

                println("✅ JWT 인증 성공: userId=$userId, email=$email")
            }
        } catch (ex: Exception) {
            // JWT 검증 실패 시 에러 로그만 남기고 계속 진행
            // → Spring Security가 나중에 401 응답 처리
            logger.error("JWT 인증 실패: ${ex.message}", ex)
        }

        // 7. 다음 필터로 진행 (인증 실패 시에도 계속 진행)
        filterChain.doFilter(request, response)
    }

    /**
     * HTTP 요청에서 JWT 토큰 추출
     *
     * Authorization 헤더 형식: "Bearer eyJhbGciOiJIUzI1NiIs..."
     *
     * @return JWT 토큰 문자열 (Bearer 제외) 또는 null
     *
     * 예시:
     * ```
     * GET /api/workspaces
     * Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
     *                       ↑ 이 부분만 추출
     * ```
     */
    private fun extractJwtFromRequest(request: HttpServletRequest): String? {
        // Authorization 헤더 읽기
        val bearerToken = request.getHeader("Authorization")

        // "Bearer "로 시작하는지 확인 (대소문자 구분)
        return if (bearerToken != null && bearerToken.startsWith("Bearer ")) {
            // "Bearer " 제거하고 토큰만 반환
            bearerToken.substring(7)
        } else {
            null
        }
    }

    /**
     * 특정 경로는 JWT 검증 생략
     *
     * 예: 로그인 API, 공개 페이지 등
     *
     * Override 예시:
     * ```
     * override fun shouldNotFilter(request: HttpServletRequest): Boolean {
     *     val path = request.requestURI
     *     return path.startsWith("/api/auth/") ||
     *            path.startsWith("/public/")
     * }
     * ```
     */
}
```

### 3.6 인증 흐름 전체 과정

```
[1단계: 로그인]
클라이언트                     서버
    │                          │
    │  POST /api/auth/login    │
    │  { email, password }     │
    ├─────────────────────────▶│
    │                          │ AuthService.authenticate()
    │                          │ ├─ DB에서 사용자 조회
    │                          │ ├─ 비밀번호 검증
    │                          │ └─ JWT 생성
    │                          │
    │  { token: "eyJ..." }     │
    │◀─────────────────────────┤
    │                          │
    │ localStorage에 저장       │
    │                          │

[2단계: 인증이 필요한 API 호출]
클라이언트                     서버
    │                          │
    │  GET /api/workspaces     │
    │  Authorization:          │
    │  Bearer eyJ...           │
    ├─────────────────────────▶│
    │                          │ 1. JwtAuthenticationFilter
    │                          │    ├─ JWT 추출
    │                          │    ├─ 서명 검증
    │                          │    ├─ 만료 확인
    │                          │    └─ SecurityContext 설정
    │                          │
    │                          │ 2. SecurityFilterChain
    │                          │    ├─ 인증 확인
    │                          │    └─ 권한 확인
    │                          │
    │                          │ 3. WorkspaceController
    │                          │    ├─ @AuthenticationPrincipal로
    │                          │    │  사용자 ID 접근
    │                          │    └─ 비즈니스 로직 실행
    │                          │
    │  [ 워크스페이스 목록 ]    │
    │◀─────────────────────────┤
    │                          │

[실패 케이스]
❌ JWT 없음
   → 401 Unauthorized

❌ JWT 만료
   → 401 Unauthorized
   → 클라이언트: 로그인 페이지로 리다이렉트

❌ JWT 위조
   → 401 Unauthorized
```

---

## 4. Spring Security 설정

### 4.1 Spring Security란?

**Spring Security**: Java/Spring 애플리케이션의 인증(Authentication)과 인가(Authorization)를 담당하는 보안 프레임워크

```
[인증 vs 인가]

인증 (Authentication)
"당신은 누구인가?"
- 로그인
- 신원 확인
예: "저는 홍길동입니다" (ID/비밀번호 제시)

인가 (Authorization)
"당신은 무엇을 할 수 있는가?"
- 권한 확인
- 접근 제어
예: "관리자만 사용자 삭제 가능"
```

### 4.2 Filter Chain 개념

```
[HTTP 요청이 Controller에 도달하기 전 여러 필터를 거침]

HTTP 요청
    │
    ├─▶ [Filter 1] CORS 필터
    │   └─ OPTIONS 요청 처리
    │
    ├─▶ [Filter 2] JwtAuthenticationFilter ← 우리가 만든 필터
    │   └─ JWT 검증
    │
    ├─▶ [Filter 3] AuthorizationFilter
    │   └─ 권한 확인
    │
    ├─▶ [Filter 4] ExceptionTranslationFilter
    │   └─ 보안 예외 처리
    │
    └─▶ Controller
        └─ 비즈니스 로직 실행
```

### 4.3 구현 코드: SecurityConfig

**파일**: `src/main/kotlin/net/meeemo/chat/config/SecurityConfig.kt`

```kotlin
package net.meeemo.chat.config

import net.meeemo.chat.security.JwtAuthenticationFilter
import org.springframework.context.annotation.Bean
import org.springframework.context.annotation.Configuration
import org.springframework.security.config.annotation.web.builders.HttpSecurity
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity
import org.springframework.security.config.http.SessionCreationPolicy
import org.springframework.security.web.SecurityFilterChain
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter
import org.springframework.web.cors.CorsConfiguration
import org.springframework.web.cors.CorsConfigurationSource
import org.springframework.web.cors.UrlBasedCorsConfigurationSource

/**
 * Spring Security 설정
 *
 * 핵심 역할:
 * 1. 어떤 URL은 인증 필요 / 어떤 URL은 공개
 * 2. JWT 필터를 Filter Chain에 추가
 * 3. CORS 설정
 * 4. CSRF 비활성화 (REST API에서는 불필요)
 */
@Configuration
@EnableWebSecurity  // Spring Security 활성화
class SecurityConfig(
    private val jwtAuthenticationFilter: JwtAuthenticationFilter
) {

    /**
     * Security Filter Chain 설정
     *
     * Spring Security 6.x 방식 (람다 DSL)
     */
    @Bean
    fun securityFilterChain(http: HttpSecurity): SecurityFilterChain {
        http
            // 1. CSRF 보호 비활성화
            .csrf { it.disable() }
            // 설명: REST API는 상태를 저장하지 않으므로 CSRF 공격 대상 아님
            // CSRF: 사용자가 의도하지 않은 요청을 하도록 유도하는 공격

            // 2. CORS 설정 적용
            .cors { it.configurationSource(corsConfigurationSource()) }
            // 설명: 다른 도메인에서 API 호출 허용 (프론트엔드 분리 시)

            // 3. URL별 인증 규칙 설정
            .authorizeHttpRequests { auth ->
                auth
                    // 공개 API (인증 불필요)
                    .requestMatchers(
                        "/api/auth/**",       // 로그인, 회원가입
                        "/api/ws/**",         // WebSocket
                        "/h2-console/**",     // H2 DB 콘솔
                        "/",                  // 메인 페이지
                        "/index.html",
                        "/css/**",
                        "/js/**",
                        "/favicon.ico"
                    ).permitAll()

                    // 나머지 모든 요청: 인증 필요
                    .anyRequest().authenticated()
            }
            // 설명:
            // - permitAll(): 누구나 접근 가능
            // - authenticated(): 인증된 사용자만 접근
            // - hasRole("ADMIN"): 특정 역할 필요 (추후 구현)

            // 4. 세션 관리 정책: Stateless
            .sessionManagement {
                it.sessionCreationPolicy(SessionCreationPolicy.STATELESS)
            }
            // 설명:
            // - STATELESS: 서버가 세션을 저장하지 않음 (JWT 방식)
            // - ALWAYS: 항상 세션 생성 (전통적 방식)

            // 5. JWT 필터 추가
            .addFilterBefore(
                jwtAuthenticationFilter,
                UsernamePasswordAuthenticationFilter::class.java
            )
            // 설명: UsernamePasswordAuthenticationFilter 이전에 JWT 필터 실행

            // 6. H2 콘솔 사용 시 추가 설정
            .headers { it.frameOptions { frameOptions -> frameOptions.disable() } }
            // 설명: H2 콘솔은 iframe 사용 → X-Frame-Options 헤더 비활성화

        return http.build()
    }

    /**
     * CORS 설정
     *
     * CORS (Cross-Origin Resource Sharing)
     * - 다른 도메인에서 API 호출 허용
     * - 브라우저 보안 정책으로 기본적으로 차단됨
     *
     * 시나리오:
     * 프론트엔드: http://localhost:3000
     * 백엔드: http://localhost:8080
     * → CORS 설정 없으면 API 호출 차단
     */
    @Bean
    fun corsConfigurationSource(): CorsConfigurationSource {
        val configuration = CorsConfiguration().apply {
            // 1. 허용할 Origin (도메인)
            allowedOrigins = listOf(
                "http://localhost:3000",   // React 개발 서버
                "http://localhost:8080"    // 같은 서버
            )
            // 프로덕션: 실제 도메인으로 변경
            // allowedOrigins = listOf("https://your-domain.com")

            // 2. 허용할 HTTP 메서드
            allowedMethods = listOf(
                "GET",
                "POST",
                "PUT",
                "DELETE",
                "OPTIONS"  // Preflight 요청용
            )

            // 3. 허용할 헤더
            allowedHeaders = listOf("*")  // 모든 헤더 허용
            // 프로덕션: 명시적으로 지정 권장
            // allowedHeaders = listOf("Authorization", "Content-Type")

            // 4. 인증 정보 포함 허용 (쿠키, Authorization 헤더)
            allowCredentials = true

            // 5. Preflight 요청 캐싱 시간 (초)
            maxAge = 3600L  // 1시간
        }

        // 모든 경로에 CORS 설정 적용
        return UrlBasedCorsConfigurationSource().apply {
            registerCorsConfiguration("/**", configuration)
        }
    }

    /**
     * 비밀번호 암호화 (추후 OAuth 전환 시에도 유용)
     *
     * BCrypt: 단방향 해시 알고리즘
     * - 같은 비밀번호도 매번 다른 해시 생성 (Salt 자동 추가)
     * - 느린 알고리즘 → 무차별 대입 공격 방어
     */
    @Bean
    fun passwordEncoder(): org.springframework.security.crypto.password.PasswordEncoder {
        return org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder()
    }
}
```

### 4.4 실제 동작 예시

```
[시나리오 1: 로그인 API 호출]

GET /api/auth/login
→ Security Filter Chain 진입
→ requestMatchers("/api/auth/**").permitAll() 매칭
→ JWT 필터 실행 안 함 (공개 API)
→ Controller 도달
→ 로그인 처리
→ JWT 토큰 반환

[시나리오 2: 인증이 필요한 API 호출 (성공)]

GET /api/workspaces
Authorization: Bearer eyJhbGci...

→ Security Filter Chain 진입
→ JwtAuthenticationFilter 실행
   ├─ JWT 추출: eyJhbGci...
   ├─ 서명 검증: ✅ 유효
   ├─ 만료 확인: ✅ 유효 (2시간 남음)
   └─ SecurityContext 설정
→ authorizeHttpRequests: authenticated() 확인
   └─ SecurityContext에 인증 정보 있음 ✅
→ Controller 도달
→ 워크스페이스 목록 반환

[시나리오 3: JWT 없이 API 호출 (실패)]

GET /api/workspaces
(Authorization 헤더 없음)

→ Security Filter Chain 진입
→ JwtAuthenticationFilter 실행
   └─ JWT 없음 (SecurityContext 설정 안 함)
→ authorizeHttpRequests: authenticated() 확인
   └─ SecurityContext에 인증 정보 없음 ❌
→ 401 Unauthorized 응답
→ Controller 도달 안 함

[시나리오 4: 만료된 JWT (실패)]

GET /api/workspaces
Authorization: Bearer eyJhbGci... (만료됨)

→ Security Filter Chain 진입
→ JwtAuthenticationFilter 실행
   ├─ JWT 추출: eyJhbGci...
   ├─ 서명 검증: ✅ 유효
   └─ 만료 확인: ❌ 만료됨 (ExpiredJwtException)
→ SecurityContext 설정 안 함
→ 401 Unauthorized 응답
```

---

## 5. 구현 순서

Phase 1을 단계별로 구현하는 순서입니다.

### 5.1 Step 1: 의존성 추가 (10분)

**파일**: `build.gradle`

```gradle
dependencies {
    // 기존 의존성...

    // JMS & ActiveMQ Artemis
    implementation 'org.springframework.boot:spring-boot-starter-artemis'
    implementation 'org.apache.activemq:artemis-jakarta-server:2.31.0'
    implementation 'org.apache.activemq:artemis-jakarta-client:2.31.0'

    // JWT
    implementation 'io.jsonwebtoken:jjwt-api:0.12.3'
    runtimeOnly 'io.jsonwebtoken:jjwt-impl:0.12.3'
    runtimeOnly 'io.jsonwebtoken:jjwt-jackson:0.12.3'

    // Spring Security
    implementation 'org.springframework.boot:spring-boot-starter-security'

    // Caffeine Cache
    implementation 'org.springframework.boot:spring-boot-starter-cache'
    implementation 'com.github.ben-manes.caffeine:caffeine:3.1.8'
}
```

**확인**:
```bash
./gradlew build
```

### 5.2 Step 2: application.yml 설정 (10분)

**파일**: `src/main/resources/application.yml`

```yaml
spring:
  application:
    name: simple-chat-app

  # Artemis 설정
  artemis:
    mode: embedded       # 임베디드 모드 (개발용)
    embedded:
      enabled: true
      persistent: false  # 인메모리

  # Security 설정
  security:
    user:
      name: admin
      password: admin

# JWT 설정
jwt:
  secret: your-256-bit-secret-key-change-this-in-production-please-use-env-variable
  expiration: 86400000  # 24시간 (밀리초)

# 로깅
logging:
  level:
    net.meeemo.chat: DEBUG
    org.apache.activemq: INFO
    org.springframework.security: DEBUG
```

### 5.3 Step 3: 인메모리 저장소 구현 (30분)

1. `UserSessionStore.kt` 작성 (위 코드 참고)
2. `ChannelSubscriptionStore.kt` 작성
3. `MessageCacheStore.kt` 작성

**테스트**:
```kotlin
@SpringBootTest
class UserSessionStoreTest {
    @Autowired
    lateinit var store: UserSessionStore

    @Test
    fun `세션 추가 및 조회`() {
        val session = UserSessionStore.UserSession(
            userId = "1",
            username = "테스트",
            email = "test@example.com",
            sessionId = "session-123",
            workspaceId = "workspace-1"
        )

        store.addSession(session)

        val found = store.getSession("session-123")
        assertNotNull(found)
        assertEquals("테스트", found?.username)
    }
}
```

### 5.4 Step 4: JWT 구현 (40분)

1. `JwtTokenProvider.kt` 작성
2. `JwtAuthenticationFilter.kt` 작성

**테스트**:
```kotlin
@SpringBootTest
class JwtTokenProviderTest {
    @Autowired
    lateinit var jwtTokenProvider: JwtTokenProvider

    @Test
    fun `JWT 생성 및 검증`() {
        // Given
        val userId = "1"
        val email = "test@example.com"
        val workspaceId = "workspace-1"

        // When
        val token = jwtTokenProvider.generateToken(userId, email, workspaceId)

        // Then
        assertTrue(jwtTokenProvider.validateToken(token))
        assertEquals(userId, jwtTokenProvider.getUserIdFromToken(token))
        assertEquals(email, jwtTokenProvider.getEmailFromToken(token))
    }

    @Test
    fun `만료된 JWT는 검증 실패`() {
        // 만료 시간을 -1초로 설정한 토큰 생성 (테스트용)
        // ...
    }
}
```

### 5.5 Step 5: Security 설정 (20분)

1. `SecurityConfig.kt` 작성
2. JWT 필터 등록

**확인**:
```bash
# 애플리케이션 시작
./gradlew bootRun

# 로그 확인
# ✅ "Using generated security password" 메시지 없음
# ✅ "JwtAuthenticationFilter" 로그 출력
```

### 5.6 Step 6: JMS 설정 (30분)

1. `JmsConfig.kt` 작성
2. `MessageProducer.kt` 작성
3. `MessageConsumer.kt` 작성

**테스트**:
```kotlin
@SpringBootTest
class JmsTest {
    @Autowired
    lateinit var messageProducer: MessageProducer

    @Autowired
    lateinit var jmsTemplate: JmsTemplate

    @Test
    fun `JMS 메시지 전송 및 수신`() {
        // Given
        val message = MessageProducer.ChatMessageEvent(
            channelId = "1",
            senderId = "1",
            senderName = "테스트",
            content = "Hello JMS!",
            type = MessageType.CHAT
        )

        // When
        messageProducer.sendChatMessage(message)

        // Then
        Thread.sleep(1000)  // Consumer 처리 대기
        // DB에 메시지 저장 확인
    }
}
```

---

## 6. 테스트 방법

### 6.1 단위 테스트

각 컴포넌트를 독립적으로 테스트합니다.

```kotlin
// JwtTokenProvider 테스트
@Test
fun `토큰 생성 및 파싱`() {
    val token = jwtTokenProvider.generateToken("1", "test@example.com", "ws-1")
    val userId = jwtTokenProvider.getUserIdFromToken(token)
    assertEquals("1", userId)
}

// UserSessionStore 테스트
@Test
fun `활성 사용자 조회`() {
    // 여러 사용자 추가
    // 특정 워크스페이스의 활성 사용자만 조회 확인
}
```

### 6.2 통합 테스트

전체 흐름을 테스트합니다.

```kotlin
@SpringBootTest(webEnvironment = RANDOM_PORT)
@AutoConfigureMockMvc
class AuthenticationIntegrationTest {

    @Autowired
    lateinit var mockMvc: MockMvc

    @Test
    fun `로그인 후 API 호출`() {
        // 1. 로그인 (JWT 받기)
        val loginResult = mockMvc.perform(
            post("/api/auth/login")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""{"email": "test@example.com", "password": "1234"}""")
        ).andExpect(status().isOk)
         .andReturn()

        val token = extractTokenFromResponse(loginResult)

        // 2. JWT로 보호된 API 호출
        mockMvc.perform(
            get("/api/workspaces")
                .header("Authorization", "Bearer $token")
        ).andExpect(status().isOk)
    }

    @Test
    fun `JWT 없이 API 호출 시 401`() {
        mockMvc.perform(get("/api/workspaces"))
            .andExpect(status().isUnauthorized)
    }
}
```

### 6.3 수동 테스트 (Postman)

**Step 1: 로그인**
```http
POST http://localhost:8080/api/auth/login
Content-Type: application/json

{
  "email": "test@example.com",
  "password": "password123"
}

응답:
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "user": {
    "id": "1",
    "email": "test@example.com",
    "name": "테스트 사용자"
  }
}
```

**Step 2: 토큰으로 API 호출**
```http
GET http://localhost:8080/api/workspaces
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...

응답:
[
  {
    "id": 1,
    "name": "My Workspace",
    "inviteCode": "123456"
  }
]
```

**Step 3: JWT 디버깅 (jwt.io)**
1. https://jwt.io 방문
2. 받은 토큰 붙여넣기
3. Payload 확인:
```json
{
  "sub": "1",
  "email": "test@example.com",
  "workspaceId": "workspace-1",
  "iat": 1699000000,
  "exp": 1699086400
}
```

---

## 7. 트러블슈팅

### 문제 1: Artemis 시작 실패

**증상**:
```
Failed to start embedded Artemis server
```

**해결**:
```yaml
# application.yml에 추가
spring:
  artemis:
    embedded:
      server-id: 0  # 서버 ID 명시
```

### 문제 2: JWT 서명 검증 실패

**증상**:
```
SignatureException: JWT signature does not match
```

**원인**: secret key가 256비트 미만

**해결**:
```yaml
jwt:
  secret: at-least-32-characters-long-secret-key-here!!
  # 최소 32자 이상
```

### 문제 3: CORS 에러

**증상**:
```
Access to XMLHttpRequest at 'http://localhost:8080/api/workspaces'
from origin 'http://localhost:3000' has been blocked by CORS policy
```

**해결**:
```kotlin
// SecurityConfig.kt
allowedOrigins = listOf(
    "http://localhost:3000"  // 프론트엔드 주소 추가
)
```

---

## 다음 단계

Phase 1 완료 후:

✅ JMS 메시지 큐 작동
✅ JWT 인증 시스템 구축
✅ 인메모리 저장소 준비
✅ Spring Security 설정 완료

**Phase 2 예고**:
- Google OAuth 2.0 로그인
- Workspace/Channel CRUD API
- 실시간 메시징 시스템

---

## 참고 자료

- [Spring Security 공식 문서](https://docs.spring.io/spring-security/reference/index.html)
- [JWT 소개 (jwt.io)](https://jwt.io/introduction)
- [ActiveMQ Artemis 문서](https://activemq.apache.org/components/artemis/documentation/)
- [Spring JMS 가이드](https://spring.io/guides/gs/messaging-jms/)

---

**작성일**: 2025-11-21
**작성자**: Claude AI
**버전**: 1.0
