# Slack 스타일 채팅 앱 구현 계획서

> **프로젝트**: simple-chat-app → Slack-like Chat Application
> **작성일**: 2025-11-13
> **기술 스택**: Spring Boot + Kotlin + OAuth Google + JMS + WebSocket
> **전략**: 기존 H2/JPA 유지 + 신규 기능 추가 (Hybrid Architecture)

---

## 📋 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [아키텍처 설계](#2-아키텍처-설계)
3. [기술 스택 상세](#3-기술-스택-상세)
4. [단계별 구현 계획](#4-단계별-구현-계획)
5. [데이터 모델 설계](#5-데이터-모델-설계)
6. [API 설계](#6-api-설계)
7. [의존성 추가](#7-의존성-추가)
8. [설정 파일](#8-설정-파일)
9. [디렉토리 구조](#9-디렉토리-구조)
10. [테스트 전략](#10-테스트-전략)
11. [배포 고려사항](#11-배포-고려사항)

---

## 1. 프로젝트 개요

### 1.1 목표
- Slack과 유사한 실시간 협업 채팅 플랫폼 구축
- 워크스페이스/채널 기반 메시징 시스템
- Google OAuth 기반 간편 인증
- JMS를 통한 안정적 메시지 전달
- WebSocket 기반 실시간 통신

### 1.2 핵심 기능
- ✅ **워크스페이스 관리**: 팀별 독립된 작업 공간
- ✅ **채널 시스템**: 주제별 채팅방 생성 및 관리
- ✅ **실시간 메시징**: WebSocket + JMS 조합
- ✅ **사용자 인증**: Google OAuth 2.0
- ✅ **사용자 상태**: 온라인/오프라인/자리비움
- ✅ **다이렉트 메시지**: 1:1 개인 메시지
- ✅ **메시지 히스토리**: DB 영구 저장 + 메모리 캐싱

### 1.3 제약사항
- DB는 보조적으로만 사용 (메시지 히스토리, 워크스페이스 정보)
- 실시간 데이터는 인메모리 캐시 우선
- 프로덕션 환경: H2 → PostgreSQL 전환 권장 (선택사항)

---

## 2. 아키텍처 설계

### 2.1 전체 시스템 아키텍처

```
┌───────────────────────────────────────────────────────────────┐
│                    클라이언트 (React/Vue/Vanilla JS)            │
│         - 워크스페이스 선택                                      │
│         - 채널 목록 및 채팅                                      │
│         - 사용자 상태 표시                                       │
└─────────────────────┬─────────────────────────────────────────┘
                      │
        ┌─────────────┴────────────┐
        │                          │
    HTTP REST                 WebSocket STOMP
    (인증, CRUD)               (실시간 메시징)
        │                          │
        ▼                          ▼
┌───────────────────────────────────────────────────────────────┐
│                     Spring Boot Application                    │
├───────────────────────────────────────────────────────────────┤
│  【Controller Layer】                                          │
│  ├─ AuthController          : OAuth 로그인/로그아웃           │
│  ├─ WorkspaceController     : 워크스페이스 CRUD               │
│  ├─ ChannelController       : 채널 CRUD                       │
│  ├─ ChatMessageController   : WebSocket 메시지 핸들링         │
│  └─ UserController          : 사용자 정보 조회                │
├───────────────────────────────────────────────────────────────┤
│  【Service Layer】                                             │
│  ├─ AuthService             : OAuth 인증, JWT 발급            │
│  ├─ WorkspaceService        : 워크스페이스 관리               │
│  ├─ ChannelService          : 채널 관리, 멤버 초대            │
│  ├─ MessageService          : 메시지 저장, JMS 발행           │
│  ├─ UserPresenceService     : 사용자 온라인 상태 관리         │
│  └─ CacheService            : Redis/Caffeine 캐시 관리        │
├───────────────────────────────────────────────────────────────┤
│  【Messaging Layer】                                           │
│  ├─ JMS Producer            : 메시지를 큐에 전송              │
│  ├─ JMS Consumer            : 큐에서 메시지 수신              │
│  └─ WebSocketBroadcaster    : 연결된 클라이언트에 전파        │
├───────────────────────────────────────────────────────────────┤
│  【Data Layer】                                                │
│  ├─ JPA Repositories        : DB 영구 저장                    │
│  │  ├─ WorkspaceRepository                                    │
│  │  ├─ ChannelRepository                                      │
│  │  ├─ MessageRepository                                      │
│  │  └─ UserRepository                                         │
│  └─ In-Memory Stores        : 실시간 데이터                   │
│     ├─ UserSessionStore     : 온라인 사용자 세션              │
│     ├─ ChannelSubscriptionStore : 채널 구독 정보             │
│     └─ MessageCacheStore    : 최근 메시지 캐시                │
└─────────────────────┬─────────────────────────────────────────┘
                      │
        ┌─────────────┴────────────┐
        │                          │
        ▼                          ▼
┌──────────────────┐       ┌──────────────────┐
│  ActiveMQ Artemis│       │  H2/PostgreSQL   │
│  (메시지 큐)      │       │  (영구 저장소)    │
│                  │       │                  │
│  - chat.queue    │       │  - workspaces    │
│  - notification  │       │  - channels      │
│  - presence      │       │  - messages      │
└──────────────────┘       │  - users         │
                           └──────────────────┘
```

### 2.2 메시지 흐름

```
[사용자 A가 메시지 전송]
   │
   │ 1. WebSocket STOMP
   ▼
ChatMessageController (@MessageMapping)
   │
   │ 2. JMS Send
   ▼
ActiveMQ Artemis Queue
   │
   │ 3. JMS Listener
   ▼
MessageConsumer (@JmsListener)
   │
   ├─ 4a. DB 저장 (비동기)
   │     MessageRepository.save()
   │
   └─ 4b. WebSocket Broadcast
         SimpMessagingTemplate.convertAndSend()
              │
              ▼
         [채널 구독자 모두에게 전달]
```

### 2.3 인증 흐름

```
[구글 로그인 버튼 클릭]
   │
   │ 1. Redirect to Google OAuth
   ▼
Google Authorization Server
   │
   │ 2. Authorization Code
   ▼
AuthController.handleGoogleCallback()
   │
   │ 3. Exchange Code for Token
   ▼
AuthService.authenticate()
   │
   ├─ 4. Get User Info from Google
   ├─ 5. Create/Update User in DB
   ├─ 6. Generate JWT Token
   └─ 7. Store Session in Memory
         │
         ▼
   [JWT 반환 → 클라이언트 저장]
         │
         │ 8. 이후 모든 요청에 JWT 포함
         ▼
   JwtAuthenticationFilter
         │
         ├─ 유효 → Controller 진행
         └─ 무효 → 401 Unauthorized
```

---

## 3. 기술 스택 상세

### 3.1 백엔드

| 기술 | 버전 | 용도 |
|------|------|------|
| **Spring Boot** | 3.2.2 | 애플리케이션 프레임워크 |
| **Kotlin** | 1.9.22 | 주 개발 언어 |
| **Spring WebSocket** | 3.2.2 | 실시간 통신 |
| **Spring JMS** | 3.2.2 | 메시지 큐 처리 |
| **ActiveMQ Artemis** | 2.31.0 | JMS 브로커 (임베디드) |
| **Spring Data JPA** | 3.2.2 | DB ORM |
| **H2 Database** | 2.2.224 | 개발용 DB (인메모리) |
| **Spring Security** | 3.2.2 | 인증/인가 |
| **Spring OAuth2 Client** | 3.2.2 | OAuth 클라이언트 |
| **JWT (jjwt)** | 0.12.3 | 토큰 생성/검증 |
| **Caffeine Cache** | 3.1.8 | 인메모리 캐싱 |
| **Jackson Kotlin** | 2.15.3 | JSON 직렬화 |

### 3.2 프론트엔드

| 기술 | 버전 | 용도 |
|------|------|------|
| **STOMP.js** | 7.0.0 | WebSocket 클라이언트 |
| **SockJS** | 1.6.1 | WebSocket 폴백 |
| **Vanilla JS** | ES6+ | 초기 구현 (추후 React 전환 가능) |
| **Bootstrap** | 5.3.2 | UI 프레임워크 |

### 3.3 개발 도구

- **Gradle** 8.5
- **Java** 17
- **IntelliJ IDEA** (권장)
- **Postman** (API 테스트)
- **H2 Console** (DB 확인)

---

## 4. 단계별 구현 계획

### Phase 1: 기본 인프라 구축 (1-2일)

#### 1.1 의존성 추가
```kotlin
// build.gradle
dependencies {
    // JMS
    implementation("org.springframework.boot:spring-boot-starter-artemis")
    implementation("org.apache.activemq:artemis-jakarta-server:2.31.0")

    // JWT
    implementation("io.jsonwebtoken:jjwt-api:0.12.3")
    runtimeOnly("io.jsonwebtoken:jjwt-impl:0.12.3")
    runtimeOnly("io.jsonwebtoken:jjwt-jackson:0.12.3")

    // Cache
    implementation("com.github.ben-manes.caffeine:caffeine:3.1.8")
    implementation("org.springframework.boot:spring-boot-starter-cache")

    // Security
    implementation("org.springframework.boot:spring-boot-starter-security")
    implementation("org.springframework.boot:spring-boot-starter-oauth2-client")

    // WebSocket (이미 있음)
    implementation("org.springframework.boot:spring-boot-starter-websocket")
}
```

#### 1.2 ActiveMQ Artemis 설정
**파일**: `src/main/kotlin/net/meeemo/chat/config/JmsConfig.kt`
```kotlin
@Configuration
@EnableJms
class JmsConfig {

    @Bean
    fun artemisConfig(): org.apache.activemq.artemis.core.config.Configuration {
        val config = ConfigurationImpl()
        config.isPersistenceEnabled = false // 인메모리 모드
        config.isSecurityEnabled = false
        config.addAcceptorConfiguration("in-vm", "vm://0")

        // Queue 설정
        config.addQueueConfiguration(
            QueueConfiguration("chat.messages")
                .setRoutingType(RoutingType.ANYCAST)
        )
        config.addQueueConfiguration(
            QueueConfiguration("user.presence")
                .setRoutingType(RoutingType.ANYCAST)
        )

        return config
    }

    @Bean
    fun artemisServer(config: org.apache.activemq.artemis.core.config.Configuration): EmbeddedActiveMQ {
        val server = EmbeddedActiveMQ()
        server.setConfiguration(config)
        return server
    }
}
```

#### 1.3 인메모리 저장소 구현
**파일**: `src/main/kotlin/net/meeemo/chat/store/UserSessionStore.kt`
```kotlin
@Component
class UserSessionStore {
    private val sessions = ConcurrentHashMap<String, UserSession>()

    data class UserSession(
        val userId: String,
        val username: String,
        val email: String,
        val sessionId: String,
        val workspaceId: String,
        val status: UserStatus = UserStatus.ONLINE,
        val lastActive: LocalDateTime = LocalDateTime.now()
    )

    enum class UserStatus {
        ONLINE, AWAY, OFFLINE
    }

    fun addSession(session: UserSession) {
        sessions[session.sessionId] = session
    }

    fun removeSession(sessionId: String) {
        sessions.remove(sessionId)
    }

    fun getSession(sessionId: String): UserSession? = sessions[sessionId]

    fun getActiveUsers(workspaceId: String): List<UserSession> {
        return sessions.values
            .filter { it.workspaceId == workspaceId && it.status == UserStatus.ONLINE }
    }

    fun updateStatus(sessionId: String, status: UserStatus) {
        sessions[sessionId]?.let {
            sessions[sessionId] = it.copy(status = status, lastActive = LocalDateTime.now())
        }
    }
}
```

**파일**: `src/main/kotlin/net/meeemo/chat/store/ChannelSubscriptionStore.kt`
```kotlin
@Component
class ChannelSubscriptionStore {
    // channelId -> Set<sessionId>
    private val subscriptions = ConcurrentHashMap<String, MutableSet<String>>()

    fun subscribe(channelId: String, sessionId: String) {
        subscriptions.computeIfAbsent(channelId) { ConcurrentHashMap.newKeySet() }
            .add(sessionId)
    }

    fun unsubscribe(channelId: String, sessionId: String) {
        subscriptions[channelId]?.remove(sessionId)
    }

    fun getSubscribers(channelId: String): Set<String> {
        return subscriptions[channelId] ?: emptySet()
    }

    fun unsubscribeAll(sessionId: String) {
        subscriptions.values.forEach { it.remove(sessionId) }
    }
}
```

**파일**: `src/main/kotlin/net/meeemo/chat/store/MessageCacheStore.kt`
```kotlin
@Component
class MessageCacheStore {
    companion object {
        private const val MAX_CACHE_SIZE = 100
    }

    // channelId -> LinkedList<Message> (최근 100개만 캐싱)
    private val cache = ConcurrentHashMap<String, LinkedList<CachedMessage>>()

    data class CachedMessage(
        val id: String,
        val content: String,
        val senderId: String,
        val senderName: String,
        val channelId: String,
        val timestamp: LocalDateTime
    )

    fun addMessage(message: CachedMessage) {
        cache.computeIfAbsent(message.channelId) { LinkedList() }
            .apply {
                addFirst(message)
                if (size > MAX_CACHE_SIZE) {
                    removeLast()
                }
            }
    }

    fun getRecentMessages(channelId: String, limit: Int = 50): List<CachedMessage> {
        return cache[channelId]?.take(limit) ?: emptyList()
    }

    fun clearChannel(channelId: String) {
        cache.remove(channelId)
    }
}
```

---

### Phase 2: 인증 & 세션 관리 (2-3일)

#### 2.1 JWT 유틸리티
**파일**: `src/main/kotlin/net/meeemo/chat/security/JwtTokenProvider.kt`
```kotlin
@Component
class JwtTokenProvider {

    @Value("\${jwt.secret}")
    private lateinit var secretKey: String

    @Value("\${jwt.expiration:86400000}") // 24시간
    private var expiration: Long = 86400000

    private val key: SecretKey by lazy {
        Keys.hmacShaKeyFor(secretKey.toByteArray())
    }

    fun generateToken(userId: String, email: String, workspaceId: String): String {
        val now = Date()
        val expiryDate = Date(now.time + expiration)

        return Jwts.builder()
            .setSubject(userId)
            .claim("email", email)
            .claim("workspaceId", workspaceId)
            .setIssuedAt(now)
            .setExpiration(expiryDate)
            .signWith(key)
            .compact()
    }

    fun validateToken(token: String): Boolean {
        return try {
            Jwts.parserBuilder()
                .setSigningKey(key)
                .build()
                .parseClaimsJws(token)
            true
        } catch (e: Exception) {
            false
        }
    }

    fun getUserIdFromToken(token: String): String {
        return Jwts.parserBuilder()
            .setSigningKey(key)
            .build()
            .parseClaimsJws(token)
            .body
            .subject
    }

    fun getClaimsFromToken(token: String): Claims {
        return Jwts.parserBuilder()
            .setSigningKey(key)
            .build()
            .parseClaimsJws(token)
            .body
    }
}
```

#### 2.2 JWT 필터
**파일**: `src/main/kotlin/net/meeemo/chat/security/JwtAuthenticationFilter.kt`
```kotlin
@Component
class JwtAuthenticationFilter(
    private val jwtTokenProvider: JwtTokenProvider,
    private val userSessionStore: UserSessionStore
) : OncePerRequestFilter() {

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        try {
            val jwt = extractJwtFromRequest(request)

            if (jwt != null && jwtTokenProvider.validateToken(jwt)) {
                val userId = jwtTokenProvider.getUserIdFromToken(jwt)
                val claims = jwtTokenProvider.getClaimsFromToken(jwt)

                val authentication = UsernamePasswordAuthenticationToken(
                    userId,
                    null,
                    emptyList()
                )
                authentication.details = claims

                SecurityContextHolder.getContext().authentication = authentication
            }
        } catch (ex: Exception) {
            logger.error("Could not set user authentication in security context", ex)
        }

        filterChain.doFilter(request, response)
    }

    private fun extractJwtFromRequest(request: HttpServletRequest): String? {
        val bearerToken = request.getHeader("Authorization")
        return if (bearerToken != null && bearerToken.startsWith("Bearer ")) {
            bearerToken.substring(7)
        } else null
    }
}
```

#### 2.3 Security 설정
**파일**: `src/main/kotlin/net/meeemo/chat/config/SecurityConfig.kt`
```kotlin
@Configuration
@EnableWebSecurity
class SecurityConfig(
    private val jwtAuthenticationFilter: JwtAuthenticationFilter
) {

    @Bean
    fun securityFilterChain(http: HttpSecurity): SecurityFilterChain {
        http
            .csrf { it.disable() }
            .cors { it.configurationSource(corsConfigurationSource()) }
            .authorizeHttpRequests { auth ->
                auth
                    .requestMatchers("/api/auth/**", "/api/ws/**", "/h2-console/**").permitAll()
                    .anyRequest().authenticated()
            }
            .sessionManagement { it.sessionCreationPolicy(SessionCreationPolicy.STATELESS) }
            .addFilterBefore(jwtAuthenticationFilter, UsernamePasswordAuthenticationFilter::class.java)

        return http.build()
    }

    @Bean
    fun corsConfigurationSource(): CorsConfigurationSource {
        val configuration = CorsConfiguration()
        configuration.allowedOrigins = listOf("http://localhost:3000", "http://localhost:8080")
        configuration.allowedMethods = listOf("GET", "POST", "PUT", "DELETE", "OPTIONS")
        configuration.allowedHeaders = listOf("*")
        configuration.allowCredentials = true

        val source = UrlBasedCorsConfigurationSource()
        source.registerCorsConfiguration("/**", configuration)
        return source
    }
}
```

#### 2.4 Auth Service 완성
**파일**: `src/main/kotlin/net/meeemo/chat/service/AuthService.kt`
```kotlin
@Service
class AuthService(
    private val restTemplate: RestTemplate,
    private val userRepository: UserRepository,
    private val jwtTokenProvider: JwtTokenProvider,
    @Value("\${spring.security.oauth2.client.registration.google.client-id}")
    private val clientId: String,
    @Value("\${spring.security.oauth2.client.registration.google.client-secret}")
    private val clientSecret: String,
    @Value("\${spring.security.oauth2.client.registration.google.redirect-uri}")
    private val redirectUri: String
) {

    data class AuthResponse(
        val token: String,
        val user: UserDTO
    )

    data class UserDTO(
        val id: String,
        val email: String,
        val name: String,
        val picture: String?
    )

    fun authenticateWithGoogle(code: String, workspaceId: String): AuthResponse {
        // 1. Access Token 획득
        val tokenResponse = exchangeCodeForToken(code)
        val accessToken = tokenResponse["access_token"] as String

        // 2. 사용자 정보 조회
        val userInfo = getUserInfoFromGoogle(accessToken)

        // 3. DB에 사용자 저장/업데이트
        val user = saveOrUpdateUser(userInfo)

        // 4. JWT 생성
        val jwt = jwtTokenProvider.generateToken(
            userId = user.id.toString(),
            email = user.email,
            workspaceId = workspaceId
        )

        return AuthResponse(
            token = jwt,
            user = UserDTO(
                id = user.id.toString(),
                email = user.email,
                name = user.nickname,
                picture = user.picture
            )
        )
    }

    private fun exchangeCodeForToken(code: String): Map<String, Any> {
        val params = mapOf(
            "code" to code,
            "client_id" to clientId,
            "client_secret" to clientSecret,
            "redirect_uri" to redirectUri,
            "grant_type" to "authorization_code"
        )

        val response = restTemplate.postForEntity(
            "https://oauth2.googleapis.com/token",
            params,
            Map::class.java
        )

        return response.body as Map<String, Any>
    }

    private fun getUserInfoFromGoogle(accessToken: String): Map<String, Any> {
        val headers = HttpHeaders()
        headers.setBearerAuth(accessToken)

        val entity = HttpEntity<String>(headers)
        val response = restTemplate.exchange(
            "https://www.googleapis.com/oauth2/v2/userinfo",
            HttpMethod.GET,
            entity,
            Map::class.java
        )

        return response.body as Map<String, Any>
    }

    private fun saveOrUpdateUser(userInfo: Map<String, Any>): ChatUser {
        val email = userInfo["email"] as String

        return userRepository.findByEmail(email) ?: run {
            val newUser = ChatUser(
                email = email,
                nickname = userInfo["name"] as String,
                picture = userInfo["picture"] as? String,
                googleId = userInfo["id"] as String
            )
            userRepository.save(newUser)
        }
    }
}
```

---

### Phase 3: 메시징 시스템 (3-4일)

#### 3.1 Entity 확장

**파일**: `src/main/kotlin/net/meeemo/chat/model/entity/Workspace.kt`
```kotlin
@Entity
@Table(name = "workspaces")
class Workspace(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null,

    @Column(nullable = false, unique = true)
    var name: String,

    @Column(unique = true, length = 6)
    var inviteCode: String = generateCode(),

    @Column
    var description: String? = null,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "owner_id")
    var owner: ChatUser,

    @OneToMany(mappedBy = "workspace", cascade = [CascadeType.ALL])
    var channels: MutableList<Channel> = mutableListOf()

) : BaseEntity() {
    companion object {
        fun generateCode(): String = (100000..999999).random().toString()
    }
}
```

**파일**: `src/main/kotlin/net/meeemo/chat/model/entity/Channel.kt`
```kotlin
@Entity
@Table(name = "channels")
class Channel(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null,

    @Column(nullable = false)
    var name: String,

    @Column
    var description: String? = null,

    @Column(nullable = false)
    var isPrivate: Boolean = false,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "workspace_id")
    var workspace: Workspace,

    @ManyToMany
    @JoinTable(
        name = "channel_members",
        joinColumns = [JoinColumn(name = "channel_id")],
        inverseJoinColumns = [JoinColumn(name = "user_id")]
    )
    var members: MutableSet<ChatUser> = mutableSetOf(),

    @OneToMany(mappedBy = "channel", cascade = [CascadeType.ALL])
    var messages: MutableList<Message> = mutableListOf()

) : BaseEntity()
```

**파일**: `src/main/kotlin/net/meeemo/chat/model/entity/Message.kt`
```kotlin
@Entity
@Table(name = "messages", indexes = [
    Index(name = "idx_channel_created", columnList = "channel_id,created_at")
])
class Message(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null,

    @Column(nullable = false, columnDefinition = "TEXT")
    var content: String,

    @Enumerated(EnumType.STRING)
    var type: MessageType = MessageType.CHAT,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "channel_id")
    var channel: Channel,

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "sender_id")
    var sender: ChatUser,

    @Column
    var isEdited: Boolean = false,

    @Column
    var editedAt: LocalDateTime? = null

) : BaseEntity()
```

**파일**: `src/main/kotlin/net/meeemo/chat/model/entity/ChatUser.kt` (수정)
```kotlin
@Entity
@Table(name = "users")
class ChatUser(
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    var id: Long? = null,

    @Column(nullable = false, unique = true)
    var email: String,

    @Column(nullable = false)
    var nickname: String,

    @Column
    var picture: String? = null,

    @Column(unique = true)
    var googleId: String,

    @ManyToMany(mappedBy = "members")
    var channels: MutableSet<Channel> = mutableSetOf(),

    @OneToMany(mappedBy = "owner")
    var ownedWorkspaces: MutableList<Workspace> = mutableListOf()

) : BaseEntity()
```

#### 3.2 JMS Message Producer
**파일**: `src/main/kotlin/net/meeemo/chat/messaging/MessageProducer.kt`
```kotlin
@Component
class MessageProducer(
    private val jmsTemplate: JmsTemplate
) {

    companion object {
        const val CHAT_QUEUE = "chat.messages"
        const val PRESENCE_QUEUE = "user.presence"
    }

    fun sendChatMessage(message: ChatMessageEvent) {
        jmsTemplate.convertAndSend(CHAT_QUEUE, message)
    }

    fun sendPresenceUpdate(event: PresenceEvent) {
        jmsTemplate.convertAndSend(PRESENCE_QUEUE, event)
    }

    data class ChatMessageEvent(
        val channelId: String,
        val senderId: String,
        val senderName: String,
        val content: String,
        val type: MessageType,
        val timestamp: LocalDateTime = LocalDateTime.now()
    )

    data class PresenceEvent(
        val userId: String,
        val workspaceId: String,
        val status: UserSessionStore.UserStatus,
        val timestamp: LocalDateTime = LocalDateTime.now()
    )
}
```

#### 3.3 JMS Message Consumer
**파일**: `src/main/kotlin/net/meeemo/chat/messaging/MessageConsumer.kt`
```kotlin
@Component
class MessageConsumer(
    private val messagingTemplate: SimpMessagingTemplate,
    private val messageRepository: MessageRepository,
    private val channelRepository: ChannelRepository,
    private val userRepository: UserRepository,
    private val messageCacheStore: MessageCacheStore,
    private val channelSubscriptionStore: ChannelSubscriptionStore
) {

    private val logger = LoggerFactory.getLogger(MessageConsumer::class.java)

    @JmsListener(destination = MessageProducer.CHAT_QUEUE)
    fun handleChatMessage(event: MessageProducer.ChatMessageEvent) {
        try {
            // 1. DB에 저장 (비동기)
            saveMessageToDatabase(event)

            // 2. 캐시에 저장
            messageCacheStore.addMessage(
                MessageCacheStore.CachedMessage(
                    id = UUID.randomUUID().toString(),
                    content = event.content,
                    senderId = event.senderId,
                    senderName = event.senderName,
                    channelId = event.channelId,
                    timestamp = event.timestamp
                )
            )

            // 3. WebSocket으로 브로드캐스트
            val destination = "/topic/channel/${event.channelId}"
            messagingTemplate.convertAndSend(destination, event)

            logger.info("Message broadcasted to channel ${event.channelId}")

        } catch (e: Exception) {
            logger.error("Failed to process chat message", e)
        }
    }

    @JmsListener(destination = MessageProducer.PRESENCE_QUEUE)
    fun handlePresenceUpdate(event: MessageProducer.PresenceEvent) {
        try {
            val destination = "/topic/workspace/${event.workspaceId}/presence"
            messagingTemplate.convertAndSend(destination, event)

            logger.info("Presence update sent for user ${event.userId}")
        } catch (e: Exception) {
            logger.error("Failed to process presence update", e)
        }
    }

    @Async
    private fun saveMessageToDatabase(event: MessageProducer.ChatMessageEvent) {
        try {
            val channel = channelRepository.findById(event.channelId.toLong())
                .orElseThrow { IllegalArgumentException("Channel not found") }

            val sender = userRepository.findById(event.senderId.toLong())
                .orElseThrow { IllegalArgumentException("User not found") }

            val message = Message(
                content = event.content,
                type = event.type,
                channel = channel,
                sender = sender
            )

            messageRepository.save(message)
        } catch (e: Exception) {
            logger.error("Failed to save message to database", e)
        }
    }
}
```

#### 3.4 WebSocket Controller 업데이트
**파일**: `src/main/kotlin/net/meeemo/chat/controller/ChatMessageController.kt` (수정)
```kotlin
@Controller
class ChatMessageController(
    private val messageProducer: MessageProducer,
    private val channelSubscriptionStore: ChannelSubscriptionStore
) {

    @MessageMapping("/chat/send/{channelId}")
    fun sendMessage(
        @DestinationVariable channelId: String,
        @Payload chatMessage: ChatMessageDTO,
        principal: Principal
    ) {
        // JWT에서 사용자 정보 추출
        val userId = principal.name

        // JMS 큐로 메시지 발행
        messageProducer.sendChatMessage(
            MessageProducer.ChatMessageEvent(
                channelId = channelId,
                senderId = userId,
                senderName = chatMessage.senderName,
                content = chatMessage.content,
                type = chatMessage.messageType
            )
        )
    }

    @SubscribeMapping("/channel/{channelId}")
    fun subscribeToChannel(
        @DestinationVariable channelId: String,
        principal: Principal,
        @Header("simpSessionId") sessionId: String
    ) {
        // 구독 추적
        channelSubscriptionStore.subscribe(channelId, sessionId)
    }
}
```

---

### Phase 4: Slack 기능 구현 (4-5일)

#### 4.1 Workspace Controller
**파일**: `src/main/kotlin/net/meeemo/chat/controller/WorkspaceController.kt`
```kotlin
@RestController
@RequestMapping("/api/workspaces")
class WorkspaceController(
    private val workspaceService: WorkspaceService
) {

    @PostMapping
    fun createWorkspace(
        @RequestBody request: CreateWorkspaceRequest,
        principal: Principal
    ): ResponseEntity<WorkspaceDTO> {
        val userId = principal.name.toLong()
        val workspace = workspaceService.createWorkspace(request.name, request.description, userId)
        return ResponseEntity.ok(workspace)
    }

    @GetMapping
    fun getUserWorkspaces(principal: Principal): ResponseEntity<List<WorkspaceDTO>> {
        val userId = principal.name.toLong()
        val workspaces = workspaceService.getUserWorkspaces(userId)
        return ResponseEntity.ok(workspaces)
    }

    @GetMapping("/{id}")
    fun getWorkspace(@PathVariable id: Long): ResponseEntity<WorkspaceDTO> {
        val workspace = workspaceService.getWorkspace(id)
        return ResponseEntity.ok(workspace)
    }

    @PostMapping("/join")
    fun joinWorkspace(
        @RequestBody request: JoinWorkspaceRequest,
        principal: Principal
    ): ResponseEntity<WorkspaceDTO> {
        val userId = principal.name.toLong()
        val workspace = workspaceService.joinWorkspace(request.inviteCode, userId)
        return ResponseEntity.ok(workspace)
    }

    data class CreateWorkspaceRequest(
        val name: String,
        val description: String?
    )

    data class JoinWorkspaceRequest(
        val inviteCode: String
    )
}
```

#### 4.2 Channel Controller
**파일**: `src/main/kotlin/net/meeemo/chat/controller/ChannelController.kt`
```kotlin
@RestController
@RequestMapping("/api/workspaces/{workspaceId}/channels")
class ChannelController(
    private val channelService: ChannelService
) {

    @PostMapping
    fun createChannel(
        @PathVariable workspaceId: Long,
        @RequestBody request: CreateChannelRequest,
        principal: Principal
    ): ResponseEntity<ChannelDTO> {
        val userId = principal.name.toLong()
        val channel = channelService.createChannel(
            workspaceId = workspaceId,
            name = request.name,
            description = request.description,
            isPrivate = request.isPrivate,
            creatorId = userId
        )
        return ResponseEntity.ok(channel)
    }

    @GetMapping
    fun getChannels(
        @PathVariable workspaceId: Long,
        principal: Principal
    ): ResponseEntity<List<ChannelDTO>> {
        val userId = principal.name.toLong()
        val channels = channelService.getChannelsForUser(workspaceId, userId)
        return ResponseEntity.ok(channels)
    }

    @GetMapping("/{channelId}/messages")
    fun getMessages(
        @PathVariable workspaceId: Long,
        @PathVariable channelId: Long,
        @RequestParam(defaultValue = "0") page: Int,
        @RequestParam(defaultValue = "50") size: Int
    ): ResponseEntity<List<MessageDTO>> {
        val messages = channelService.getMessages(channelId, page, size)
        return ResponseEntity.ok(messages)
    }

    @PostMapping("/{channelId}/members")
    fun addMember(
        @PathVariable workspaceId: Long,
        @PathVariable channelId: Long,
        @RequestBody request: AddMemberRequest
    ): ResponseEntity<Unit> {
        channelService.addMember(channelId, request.userId)
        return ResponseEntity.ok().build()
    }

    data class CreateChannelRequest(
        val name: String,
        val description: String?,
        val isPrivate: Boolean = false
    )

    data class AddMemberRequest(
        val userId: Long
    )
}
```

#### 4.3 User Presence Service
**파일**: `src/main/kotlin/net/meeemo/chat/service/UserPresenceService.kt`
```kotlin
@Service
class UserPresenceService(
    private val userSessionStore: UserSessionStore,
    private val messageProducer: MessageProducer
) {

    fun userConnected(userId: String, sessionId: String, workspaceId: String, userInfo: UserSessionStore.UserSession) {
        userSessionStore.addSession(userInfo)

        messageProducer.sendPresenceUpdate(
            MessageProducer.PresenceEvent(
                userId = userId,
                workspaceId = workspaceId,
                status = UserSessionStore.UserStatus.ONLINE
            )
        )
    }

    fun userDisconnected(sessionId: String) {
        val session = userSessionStore.getSession(sessionId) ?: return

        userSessionStore.removeSession(sessionId)

        messageProducer.sendPresenceUpdate(
            MessageProducer.PresenceEvent(
                userId = session.userId,
                workspaceId = session.workspaceId,
                status = UserSessionStore.UserStatus.OFFLINE
            )
        )
    }

    fun updateStatus(sessionId: String, status: UserSessionStore.UserStatus) {
        val session = userSessionStore.getSession(sessionId) ?: return

        userSessionStore.updateStatus(sessionId, status)

        messageProducer.sendPresenceUpdate(
            MessageProducer.PresenceEvent(
                userId = session.userId,
                workspaceId = session.workspaceId,
                status = status
            )
        )
    }

    fun getActiveUsers(workspaceId: String): List<UserSessionStore.UserSession> {
        return userSessionStore.getActiveUsers(workspaceId)
    }
}
```

#### 4.4 WebSocket Event Listener
**파일**: `src/main/kotlin/net/meeemo/chat/listener/WebSocketEventListener.kt`
```kotlin
@Component
class WebSocketEventListener(
    private val userPresenceService: UserPresenceService,
    private val channelSubscriptionStore: ChannelSubscriptionStore
) {

    private val logger = LoggerFactory.getLogger(WebSocketEventListener::class.java)

    @EventListener
    fun handleWebSocketConnectListener(event: SessionConnectedEvent) {
        val sessionId = event.message.headers["simpSessionId"] as String
        logger.info("WebSocket connected: $sessionId")
    }

    @EventListener
    fun handleWebSocketDisconnectListener(event: SessionDisconnectEvent) {
        val sessionId = event.sessionId
        logger.info("WebSocket disconnected: $sessionId")

        // 사용자 세션 제거
        userPresenceService.userDisconnected(sessionId)

        // 채널 구독 제거
        channelSubscriptionStore.unsubscribeAll(sessionId)
    }

    @EventListener
    fun handleSubscribeEvent(event: SessionSubscribeEvent) {
        val sessionId = event.message.headers["simpSessionId"] as String
        val destination = event.message.headers["simpDestination"] as? String

        logger.info("Subscription: $sessionId -> $destination")
    }
}
```

---

### Phase 5: UI/UX 개선 (3-4일)

#### 5.1 Slack 스타일 레이아웃
**파일**: `src/main/resources/templates/index.html` (Mustache → HTML 전환)
```html
<!DOCTYPE html>
<html lang="ko">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Slack-like Chat App</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.2/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="/css/slack-style.css">
</head>
<body>
    <!-- 로그인 화면 -->
    <div id="loginScreen" class="container">
        <div class="text-center mt-5">
            <h1>Chat App</h1>
            <button id="googleLogin" class="btn btn-primary mt-3">
                Sign in with Google
            </button>
        </div>
    </div>

    <!-- 메인 화면 (로그인 후 표시) -->
    <div id="mainScreen" class="d-none">
        <!-- 좌측 사이드바: 워크스페이스 & 채널 -->
        <div class="sidebar">
            <div class="workspace-header">
                <h4 id="workspaceName">Workspace</h4>
            </div>

            <div class="channels-section">
                <div class="section-header">
                    <span>Channels</span>
                    <button id="addChannel" class="btn-icon">+</button>
                </div>
                <ul id="channelList" class="channel-list"></ul>
            </div>

            <div class="dm-section">
                <div class="section-header">
                    <span>Direct Messages</span>
                    <button id="addDM" class="btn-icon">+</button>
                </div>
                <ul id="dmList" class="dm-list"></ul>
            </div>

            <div class="user-section">
                <div class="user-info">
                    <img id="userAvatar" class="avatar" src="" alt="Avatar">
                    <span id="userName"></span>
                    <select id="statusSelect" class="status-select">
                        <option value="ONLINE">🟢 Active</option>
                        <option value="AWAY">🟡 Away</option>
                    </select>
                </div>
            </div>
        </div>

        <!-- 메인 채팅 영역 -->
        <div class="chat-area">
            <div class="chat-header">
                <h3 id="currentChannelName">#general</h3>
                <div class="header-actions">
                    <button id="channelInfo" class="btn-icon">ℹ️</button>
                    <button id="searchMessages" class="btn-icon">🔍</button>
                </div>
            </div>

            <div class="messages-container" id="messagesContainer">
                <!-- 메시지들이 여기에 동적으로 추가됨 -->
            </div>

            <div class="message-input-area">
                <textarea
                    id="messageInput"
                    class="message-input"
                    placeholder="Message #general"
                    rows="1"
                ></textarea>
                <button id="sendMessage" class="btn-send">Send</button>
            </div>
        </div>

        <!-- 우측 사이드바: 멤버 목록 -->
        <div class="members-sidebar">
            <h5>Members</h5>
            <ul id="membersList" class="members-list"></ul>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/@stomp/stompjs@7.0.0/bundles/stomp.umd.min.js"></script>
    <script src="/js/app.js"></script>
</body>
</html>
```

#### 5.2 CSS 스타일
**파일**: `src/main/resources/static/css/slack-style.css`
```css
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    height: 100vh;
    overflow: hidden;
}

#mainScreen {
    display: flex;
    height: 100vh;
}

/* 좌측 사이드바 */
.sidebar {
    width: 260px;
    background-color: #3f0e40;
    color: #fff;
    display: flex;
    flex-direction: column;
}

.workspace-header {
    padding: 20px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.workspace-header h4 {
    margin: 0;
    font-size: 18px;
}

.channels-section, .dm-section {
    padding: 10px;
}

.section-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px;
    font-weight: bold;
    font-size: 14px;
}

.channel-list, .dm-list {
    list-style: none;
    padding: 0;
}

.channel-item, .dm-item {
    padding: 8px 10px;
    cursor: pointer;
    border-radius: 4px;
    transition: background-color 0.2s;
}

.channel-item:hover, .dm-item:hover {
    background-color: rgba(255, 255, 255, 0.1);
}

.channel-item.active, .dm-item.active {
    background-color: #1164a3;
}

.user-section {
    margin-top: auto;
    padding: 20px;
    border-top: 1px solid rgba(255, 255, 255, 0.1);
}

.user-info {
    display: flex;
    align-items: center;
    gap: 10px;
}

.avatar {
    width: 32px;
    height: 32px;
    border-radius: 4px;
}

/* 메인 채팅 영역 */
.chat-area {
    flex: 1;
    display: flex;
    flex-direction: column;
    background-color: #fff;
}

.chat-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 15px 20px;
    border-bottom: 1px solid #ddd;
}

.chat-header h3 {
    margin: 0;
    font-size: 20px;
}

.messages-container {
    flex: 1;
    overflow-y: auto;
    padding: 20px;
    background-color: #fff;
}

.message {
    display: flex;
    gap: 10px;
    padding: 8px 0;
}

.message:hover {
    background-color: #f8f8f8;
}

.message-avatar {
    width: 36px;
    height: 36px;
    border-radius: 4px;
    background-color: #ccc;
}

.message-content {
    flex: 1;
}

.message-header {
    display: flex;
    align-items: baseline;
    gap: 10px;
    margin-bottom: 4px;
}

.message-sender {
    font-weight: bold;
    font-size: 15px;
}

.message-time {
    font-size: 12px;
    color: #616061;
}

.message-text {
    font-size: 15px;
    line-height: 1.5;
}

.message-input-area {
    padding: 20px;
    border-top: 1px solid #ddd;
    display: flex;
    gap: 10px;
}

.message-input {
    flex: 1;
    border: 1px solid #ddd;
    border-radius: 4px;
    padding: 10px;
    font-size: 15px;
    resize: none;
    max-height: 150px;
}

.btn-send {
    background-color: #007a5a;
    color: #fff;
    border: none;
    border-radius: 4px;
    padding: 10px 20px;
    cursor: pointer;
}

.btn-send:hover {
    background-color: #005c42;
}

/* 우측 멤버 사이드바 */
.members-sidebar {
    width: 240px;
    background-color: #f8f8f8;
    border-left: 1px solid #ddd;
    padding: 20px;
}

.members-list {
    list-style: none;
    padding: 0;
}

.member-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px;
    border-radius: 4px;
    cursor: pointer;
}

.member-item:hover {
    background-color: #e8e8e8;
}

.member-status {
    width: 8px;
    height: 8px;
    border-radius: 50%;
}

.member-status.online {
    background-color: #2bac76;
}

.member-status.away {
    background-color: #f2c744;
}

.member-status.offline {
    background-color: #ccc;
}

/* 로딩 스피너 */
.spinner {
    border: 3px solid #f3f3f3;
    border-top: 3px solid #007a5a;
    border-radius: 50%;
    width: 40px;
    height: 40px;
    animation: spin 1s linear infinite;
    margin: 20px auto;
}

@keyframes spin {
    0% { transform: rotate(0deg); }
    100% { transform: rotate(360deg); }
}
```

#### 5.3 JavaScript 클라이언트
**파일**: `src/main/resources/static/js/app.js`
```javascript
class SlackChatApp {
    constructor() {
        this.stompClient = null;
        this.currentWorkspace = null;
        this.currentChannel = null;
        this.userToken = null;
        this.userId = null;

        this.init();
    }

    init() {
        this.setupEventListeners();
        this.checkAuth();
    }

    setupEventListeners() {
        // 로그인
        document.getElementById('googleLogin').addEventListener('click', () => {
            this.initiateGoogleLogin();
        });

        // 메시지 전송
        document.getElementById('sendMessage').addEventListener('click', () => {
            this.sendMessage();
        });

        document.getElementById('messageInput').addEventListener('keypress', (e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                this.sendMessage();
            }
        });

        // 상태 변경
        document.getElementById('statusSelect').addEventListener('change', (e) => {
            this.updateStatus(e.target.value);
        });
    }

    checkAuth() {
        const token = localStorage.getItem('authToken');
        if (token) {
            this.userToken = token;
            this.showMainScreen();
            this.loadUserData();
        }
    }

    initiateGoogleLogin() {
        // Google OAuth URL로 리다이렉트
        const clientId = '841826356567-95s5dgc0hglpj2p015sefimakbdgr28o.apps.googleusercontent.com';
        const redirectUri = 'http://localhost:8080/api/auth/google/callback';
        const scope = 'email profile';

        const authUrl = `https://accounts.google.com/o/oauth2/v2/auth?` +
            `client_id=${clientId}&` +
            `redirect_uri=${redirectUri}&` +
            `response_type=code&` +
            `scope=${scope}`;

        window.location.href = authUrl;
    }

    async loadUserData() {
        try {
            // 워크스페이스 목록 로드
            const workspaces = await this.fetchAPI('/api/workspaces');
            if (workspaces.length > 0) {
                this.currentWorkspace = workspaces[0];
                this.loadWorkspace();
            }
        } catch (error) {
            console.error('Failed to load user data:', error);
        }
    }

    async loadWorkspace() {
        document.getElementById('workspaceName').textContent = this.currentWorkspace.name;

        // 채널 목록 로드
        const channels = await this.fetchAPI(
            `/api/workspaces/${this.currentWorkspace.id}/channels`
        );

        this.renderChannels(channels);

        if (channels.length > 0) {
            this.selectChannel(channels[0]);
        }

        // WebSocket 연결
        this.connectWebSocket();
    }

    renderChannels(channels) {
        const channelList = document.getElementById('channelList');
        channelList.innerHTML = '';

        channels.forEach(channel => {
            const li = document.createElement('li');
            li.className = 'channel-item';
            li.textContent = `# ${channel.name}`;
            li.dataset.channelId = channel.id;
            li.addEventListener('click', () => this.selectChannel(channel));
            channelList.appendChild(li);
        });
    }

    async selectChannel(channel) {
        this.currentChannel = channel;
        document.getElementById('currentChannelName').textContent = `# ${channel.name}`;

        // 기존 채널 선택 해제
        document.querySelectorAll('.channel-item').forEach(el => {
            el.classList.remove('active');
        });

        // 새 채널 선택
        document.querySelector(`[data-channel-id="${channel.id}"]`).classList.add('active');

        // 메시지 로드
        await this.loadMessages();

        // 채널 구독
        if (this.stompClient && this.stompClient.connected) {
            this.subscribeToChannel(channel.id);
        }
    }

    async loadMessages() {
        try {
            const messages = await this.fetchAPI(
                `/api/workspaces/${this.currentWorkspace.id}/channels/${this.currentChannel.id}/messages`
            );

            this.renderMessages(messages);
        } catch (error) {
            console.error('Failed to load messages:', error);
        }
    }

    renderMessages(messages) {
        const container = document.getElementById('messagesContainer');
        container.innerHTML = '';

        messages.reverse().forEach(msg => {
            this.appendMessage(msg);
        });

        this.scrollToBottom();
    }

    appendMessage(message) {
        const container = document.getElementById('messagesContainer');

        const messageDiv = document.createElement('div');
        messageDiv.className = 'message';

        const timestamp = new Date(message.timestamp).toLocaleTimeString('ko-KR', {
            hour: '2-digit',
            minute: '2-digit'
        });

        messageDiv.innerHTML = `
            <div class="message-avatar"></div>
            <div class="message-content">
                <div class="message-header">
                    <span class="message-sender">${message.senderName}</span>
                    <span class="message-time">${timestamp}</span>
                </div>
                <div class="message-text">${this.escapeHtml(message.content)}</div>
            </div>
        `;

        container.appendChild(messageDiv);
    }

    connectWebSocket() {
        const socket = new WebSocket(`ws://localhost:8080/api/ws`);
        this.stompClient = new StompJs.Client({
            webSocketFactory: () => socket,
            connectHeaders: {
                Authorization: `Bearer ${this.userToken}`
            },
            onConnect: () => {
                console.log('WebSocket connected');
                if (this.currentChannel) {
                    this.subscribeToChannel(this.currentChannel.id);
                }
            },
            onStompError: (frame) => {
                console.error('STOMP error:', frame);
            }
        });

        this.stompClient.activate();
    }

    subscribeToChannel(channelId) {
        this.stompClient.subscribe(`/topic/channel/${channelId}`, (message) => {
            const chatMessage = JSON.parse(message.body);
            this.appendMessage(chatMessage);
            this.scrollToBottom();
        });
    }

    sendMessage() {
        const input = document.getElementById('messageInput');
        const content = input.value.trim();

        if (!content || !this.currentChannel) return;

        const message = {
            content: content,
            senderName: document.getElementById('userName').textContent,
            messageType: 'CHAT'
        };

        this.stompClient.publish({
            destination: `/app/chat/send/${this.currentChannel.id}`,
            body: JSON.stringify(message)
        });

        input.value = '';
    }

    updateStatus(status) {
        // JMS로 상태 업데이트 전송
        this.fetchAPI('/api/users/status', {
            method: 'PUT',
            body: JSON.stringify({ status })
        });
    }

    async fetchAPI(url, options = {}) {
        const defaultOptions = {
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${this.userToken}`
            }
        };

        const response = await fetch(url, { ...defaultOptions, ...options });

        if (!response.ok) {
            throw new Error(`API call failed: ${response.statusText}`);
        }

        return response.json();
    }

    showMainScreen() {
        document.getElementById('loginScreen').classList.add('d-none');
        document.getElementById('mainScreen').classList.remove('d-none');
    }

    scrollToBottom() {
        const container = document.getElementById('messagesContainer');
        container.scrollTop = container.scrollHeight;
    }

    escapeHtml(text) {
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// 앱 초기화
document.addEventListener('DOMContentLoaded', () => {
    window.chatApp = new SlackChatApp();
});
```

---

## 5. 데이터 모델 설계

### 5.1 ERD (Entity Relationship Diagram)

```
┌─────────────────┐
│    ChatUser     │
├─────────────────┤
│ id (PK)         │
│ email           │
│ nickname        │
│ picture         │
│ googleId        │
│ createdAt       │
│ updatedAt       │
└────────┬────────┘
         │
         │ 1:N (owner)
         │
         ▼
┌─────────────────┐       1:N        ┌─────────────────┐
│   Workspace     │◄─────────────────│    Channel      │
├─────────────────┤                  ├─────────────────┤
│ id (PK)         │                  │ id (PK)         │
│ name            │                  │ name            │
│ inviteCode      │                  │ description     │
│ description     │                  │ isPrivate       │
│ owner_id (FK)   │                  │ workspace_id(FK)│
│ createdAt       │                  │ createdAt       │
│ updatedAt       │                  │ updatedAt       │
└─────────────────┘                  └────────┬────────┘
                                              │
                                              │ 1:N
                                              │
                                              ▼
                                     ┌─────────────────┐
                                     │    Message      │
                                     ├─────────────────┤
                                     │ id (PK)         │
                                     │ content         │
                                     │ type            │
                                     │ channel_id (FK) │
                                     │ sender_id (FK)  │
                                     │ isEdited        │
                                     │ editedAt        │
                                     │ createdAt       │
                                     │ updatedAt       │
                                     └─────────────────┘

┌──────────────────────────────────┐
│   channel_members (조인 테이블)   │
├──────────────────────────────────┤
│ channel_id (FK)                  │
│ user_id (FK)                     │
│ joined_at                        │
└──────────────────────────────────┘
```

### 5.2 인덱스 전략

```sql
-- Message 테이블: 채널별 최신 메시지 조회 최적화
CREATE INDEX idx_message_channel_created ON messages(channel_id, created_at DESC);

-- ChatUser 테이블: 이메일 기반 로그인
CREATE UNIQUE INDEX idx_user_email ON users(email);

-- Workspace 테이블: 초대 코드 검색
CREATE UNIQUE INDEX idx_workspace_invite_code ON workspaces(invite_code);

-- Channel 테이블: 워크스페이스별 채널 조회
CREATE INDEX idx_channel_workspace ON channels(workspace_id);
```

---

## 6. API 설계

### 6.1 인증 API

| Method | Endpoint | Description | Request | Response |
|--------|----------|-------------|---------|----------|
| GET | `/api/auth/google` | Google 로그인 시작 | - | Redirect to Google |
| GET | `/api/auth/google/callback` | OAuth 콜백 처리 | `code`, `state` | `{ token, user }` |
| POST | `/api/auth/logout` | 로그아웃 | - | `200 OK` |

### 6.2 Workspace API

| Method | Endpoint | Description | Request | Response |
|--------|----------|-------------|---------|----------|
| POST | `/api/workspaces` | 워크스페이스 생성 | `{ name, description }` | `WorkspaceDTO` |
| GET | `/api/workspaces` | 내 워크스페이스 목록 | - | `List<WorkspaceDTO>` |
| GET | `/api/workspaces/{id}` | 워크스페이스 상세 | - | `WorkspaceDTO` |
| POST | `/api/workspaces/join` | 초대 코드로 참여 | `{ inviteCode }` | `WorkspaceDTO` |
| DELETE | `/api/workspaces/{id}` | 워크스페이스 삭제 | - | `200 OK` |

### 6.3 Channel API

| Method | Endpoint | Description | Request | Response |
|--------|----------|-------------|---------|----------|
| POST | `/api/workspaces/{wid}/channels` | 채널 생성 | `{ name, description, isPrivate }` | `ChannelDTO` |
| GET | `/api/workspaces/{wid}/channels` | 채널 목록 | - | `List<ChannelDTO>` |
| GET | `/api/workspaces/{wid}/channels/{cid}` | 채널 상세 | - | `ChannelDTO` |
| PUT | `/api/workspaces/{wid}/channels/{cid}` | 채널 수정 | `{ name, description }` | `ChannelDTO` |
| DELETE | `/api/workspaces/{wid}/channels/{cid}` | 채널 삭제 | - | `200 OK` |
| POST | `/api/workspaces/{wid}/channels/{cid}/members` | 멤버 추가 | `{ userId }` | `200 OK` |
| DELETE | `/api/workspaces/{wid}/channels/{cid}/members/{uid}` | 멤버 제거 | - | `200 OK` |
| GET | `/api/workspaces/{wid}/channels/{cid}/messages` | 메시지 조회 | `page`, `size` | `List<MessageDTO>` |

### 6.4 User API

| Method | Endpoint | Description | Request | Response |
|--------|----------|-------------|---------|----------|
| GET | `/api/users/me` | 내 정보 조회 | - | `UserDTO` |
| PUT | `/api/users/status` | 상태 변경 | `{ status }` | `200 OK` |
| GET | `/api/users/{id}` | 사용자 정보 조회 | - | `UserDTO` |

### 6.5 WebSocket API

| Type | Destination | Description | Payload |
|------|-------------|-------------|---------|
| SEND | `/app/chat/send/{channelId}` | 메시지 전송 | `ChatMessageDTO` |
| SUBSCRIBE | `/topic/channel/{channelId}` | 채널 메시지 구독 | - |
| SUBSCRIBE | `/topic/workspace/{wid}/presence` | 사용자 상태 구독 | - |
| SEND | `/app/user/status` | 상태 업데이트 | `{ status }` |

---

## 7. 의존성 추가

### 7.1 build.gradle 전체

```kotlin
plugins {
    id("org.springframework.boot") version "3.2.2"
    id("io.spring.dependency-management") version "1.1.4"
    kotlin("jvm") version "1.9.22"
    kotlin("plugin.spring") version "1.9.22"
    kotlin("plugin.jpa") version "1.9.22"
}

group = "net.meeemo"
version = "0.0.1-SNAPSHOT"

java {
    sourceCompatibility = JavaVersion.VERSION_17
}

repositories {
    mavenCentral()
}

dependencies {
    // Spring Boot Starters
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.springframework.boot:spring-boot-starter-websocket")
    implementation("org.springframework.boot:spring-boot-starter-data-jpa")
    implementation("org.springframework.boot:spring-boot-starter-security")
    implementation("org.springframework.boot:spring-boot-starter-oauth2-client")
    implementation("org.springframework.boot:spring-boot-starter-cache")

    // JMS & ActiveMQ Artemis
    implementation("org.springframework.boot:spring-boot-starter-artemis")
    implementation("org.apache.activemq:artemis-jakarta-server:2.31.0")
    implementation("org.apache.activemq:artemis-jakarta-client:2.31.0")

    // JWT
    implementation("io.jsonwebtoken:jjwt-api:0.12.3")
    runtimeOnly("io.jsonwebtoken:jjwt-impl:0.12.3")
    runtimeOnly("io.jsonwebtoken:jjwt-jackson:0.12.3")

    // Caffeine Cache
    implementation("com.github.ben-manes.caffeine:caffeine:3.1.8")

    // Database
    runtimeOnly("com.h2database:h2")

    // Kotlin
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin")
    implementation("org.jetbrains.kotlin:kotlin-reflect")

    // Mustache (선택사항, HTML로 전환 가능)
    implementation("org.springframework.boot:spring-boot-starter-mustache")

    // Test
    testImplementation("org.springframework.boot:spring-boot-starter-test")
    testImplementation("org.springframework.security:spring-security-test")
}

kotlin {
    compilerOptions {
        freeCompilerArgs.addAll("-Xjsr305=strict")
    }
}

tasks.withType<Test> {
    useJUnitPlatform()
}
```

---

## 8. 설정 파일

### 8.1 application.yml

```yaml
spring:
  application:
    name: slack-like-chat-app

  mvc:
    servlet:
      path: /api

  h2:
    console:
      enabled: true
      path: /h2-console

  datasource:
    driver-class-name: org.h2.Driver
    url: jdbc:h2:mem:chatdb
    username: sa
    password:

  jpa:
    hibernate:
      ddl-auto: update
    show-sql: true
    properties:
      hibernate:
        format_sql: true
        dialect: org.hibernate.dialect.H2Dialect

  # ActiveMQ Artemis 설정
  artemis:
    mode: embedded
    embedded:
      enabled: true
      persistent: false

  # Security
  security:
    oauth2:
      client:
        registration:
          google:
            client-id: ${GOOGLE_CLIENT_ID:841826356567-95s5dgc0hglpj2p015sefimakbdgr28o.apps.googleusercontent.com}
            client-secret: ${GOOGLE_CLIENT_SECRET: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}
            scope:
              - email
              - profile
            redirect-uri: http://localhost:8080/api/auth/google/callback
        provider:
          google:
            authorization-uri: https://accounts.google.com/o/oauth2/v2/auth
            token-uri: https://oauth2.googleapis.com/token
            user-info-uri: https://www.googleapis.com/oauth2/v2/userinfo

# JWT 설정
jwt:
  secret: ${JWT_SECRET:your-secret-key-min-256-bits-long-change-this-in-production}
  expiration: 86400000  # 24시간

# 로깅
logging:
  level:
    net.meeemo.chat: DEBUG
    org.springframework.messaging: DEBUG
    org.springframework.web.socket: DEBUG
```

---

## 9. 디렉토리 구조

```
src/
├── main/
│   ├── kotlin/
│   │   └── net/meeemo/chat/
│   │       ├── SimpleChatApplication.kt
│   │       ├── config/
│   │       │   ├── JmsConfig.kt
│   │       │   ├── WebSocketConfig.kt
│   │       │   ├── SecurityConfig.kt
│   │       │   └── CacheConfig.kt
│   │       ├── controller/
│   │       │   ├── AuthController.kt
│   │       │   ├── WorkspaceController.kt
│   │       │   ├── ChannelController.kt
│   │       │   ├── ChatMessageController.kt
│   │       │   └── UserController.kt
│   │       ├── service/
│   │       │   ├── AuthService.kt
│   │       │   ├── WorkspaceService.kt
│   │       │   ├── ChannelService.kt
│   │       │   ├── MessageService.kt
│   │       │   └── UserPresenceService.kt
│   │       ├── model/
│   │       │   ├── entity/
│   │       │   │   ├── base/
│   │       │   │   │   └── BaseEntity.kt
│   │       │   │   ├── ChatUser.kt
│   │       │   │   ├── Workspace.kt
│   │       │   │   ├── Channel.kt
│   │       │   │   └── Message.kt
│   │       │   ├── dto/
│   │       │   │   ├── WorkspaceDTO.kt
│   │       │   │   ├── ChannelDTO.kt
│   │       │   │   ├── MessageDTO.kt
│   │       │   │   └── ChatMessageDTO.kt
│   │       │   └── repository/
│   │       │       ├── UserRepository.kt
│   │       │       ├── WorkspaceRepository.kt
│   │       │       ├── ChannelRepository.kt
│   │       │       └── MessageRepository.kt
│   │       ├── messaging/
│   │       │   ├── MessageProducer.kt
│   │       │   └── MessageConsumer.kt
│   │       ├── security/
│   │       │   ├── JwtTokenProvider.kt
│   │       │   └── JwtAuthenticationFilter.kt
│   │       ├── store/
│   │       │   ├── UserSessionStore.kt
│   │       │   ├── ChannelSubscriptionStore.kt
│   │       │   └── MessageCacheStore.kt
│   │       ├── listener/
│   │       │   └── WebSocketEventListener.kt
│   │       └── enums/
│   │           └── MessageType.kt
│   └── resources/
│       ├── application.yml
│       ├── templates/
│       │   └── index.html
│       └── static/
│           ├── css/
│           │   └── slack-style.css
│           └── js/
│               └── app.js
└── test/
    └── kotlin/
        └── net/meeemo/chat/
            ├── SimpleChatApplicationTests.kt
            ├── controller/
            ├── service/
            └── repository/
```

---

## 10. 테스트 전략

### 10.1 단위 테스트

```kotlin
// WorkspaceServiceTest.kt
@SpringBootTest
class WorkspaceServiceTest {

    @Autowired
    private lateinit var workspaceService: WorkspaceService

    @Test
    fun `워크스페이스 생성 테스트`() {
        val workspace = workspaceService.createWorkspace(
            name = "Test Workspace",
            description = "Test Description",
            ownerId = 1L
        )

        assertNotNull(workspace.id)
        assertEquals("Test Workspace", workspace.name)
        assertEquals(6, workspace.inviteCode.length)
    }
}
```

### 10.2 통합 테스트

```kotlin
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@AutoConfigureMockMvc
class ChannelControllerIntegrationTest {

    @Autowired
    private lateinit var mockMvc: MockMvc

    @Test
    fun `채널 생성 API 테스트`() {
        mockMvc.perform(
            post("/api/workspaces/1/channels")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {
                        "name": "general",
                        "description": "General discussion",
                        "isPrivate": false
                    }
                """)
                .header("Authorization", "Bearer $token")
        )
        .andExpect(status().isOk)
        .andExpect(jsonPath("$.name").value("general"))
    }
}
```

### 10.3 WebSocket 테스트

```kotlin
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class WebSocketIntegrationTest {

    @LocalServerPort
    private var port: Int = 0

    @Test
    fun `WebSocket 메시지 전송 테스트`() {
        val stompClient = WebSocketStompClient(SockJsClient(listOf(
            WebSocketTransport(StandardWebSocketClient())
        )))

        val future = CompletableFuture<ChatMessageDTO>()

        stompClient.connect("ws://localhost:$port/api/ws", object : StompSessionHandlerAdapter() {
            override fun afterConnected(session: StompSession, connectedHeaders: StompHeaders) {
                session.subscribe("/topic/channel/1") { message ->
                    future.complete(message.payload as ChatMessageDTO)
                }

                session.send("/app/chat/send/1", ChatMessageDTO(
                    content = "Test message",
                    senderName = "Tester",
                    messageType = MessageType.CHAT
                ))
            }
        })

        val result = future.get(10, TimeUnit.SECONDS)
        assertEquals("Test message", result.content)
    }
}
```

---

## 11. 배포 고려사항

### 11.1 프로덕션 환경 설정

**application-prod.yml**
```yaml
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/chatdb
    username: ${DB_USERNAME}
    password: ${DB_PASSWORD}
    driver-class-name: org.postgresql.Driver

  jpa:
    hibernate:
      ddl-auto: validate
    show-sql: false

  artemis:
    mode: native
    broker-url: tcp://localhost:61616
    user: ${ARTEMIS_USER}
    password: ${ARTEMIS_PASSWORD}

jwt:
  secret: ${JWT_SECRET}  # 환경 변수에서 가져오기
  expiration: 3600000    # 1시간
```

### 11.2 Docker Compose

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: chatdb
      POSTGRES_USER: chatuser
      POSTGRES_PASSWORD: chatpass
    ports:
      - "5432:5432"
    volumes:
      - postgres-data:/var/lib/postgresql/data

  artemis:
    image: apache/activemq-artemis:2.31.0
    environment:
      ARTEMIS_USER: admin
      ARTEMIS_PASSWORD: admin
    ports:
      - "61616:61616"
      - "8161:8161"

  app:
    build: .
    environment:
      SPRING_PROFILES_ACTIVE: prod
      DB_USERNAME: chatuser
      DB_PASSWORD: chatpass
      ARTEMIS_USER: admin
      ARTEMIS_PASSWORD: admin
      JWT_SECRET: your-production-secret
    ports:
      - "8080:8080"
    depends_on:
      - postgres
      - artemis

volumes:
  postgres-data:
```

### 11.3 보안 체크리스트

- [ ] JWT Secret을 환경 변수로 관리
- [ ] Google OAuth credentials를 안전하게 저장
- [ ] HTTPS 적용
- [ ] CORS 설정 검토
- [ ] SQL Injection 방어 확인
- [ ] XSS 방어 확인
- [ ] Rate Limiting 구현
- [ ] 입력 검증 강화

---

## 12. 구현 순서 체크리스트

### Week 1: 기본 인프라
- [ ] JMS 의존성 추가 및 ActiveMQ Artemis 설정
- [ ] 인메모리 저장소 구현 (UserSessionStore, ChannelSubscriptionStore, MessageCacheStore)
- [ ] JWT 인증 구현 (JwtTokenProvider, JwtAuthenticationFilter)
- [ ] Security 설정 완료

### Week 2: 인증 & 데이터 모델
- [ ] OAuth 인증 완성 (AuthService, AuthController)
- [ ] Entity 확장 (Workspace, Channel, Message, ChatUser)
- [ ] Repository 구현
- [ ] DTO 작성

### Week 3: 메시징 시스템
- [ ] JMS Producer/Consumer 구현
- [ ] WebSocket Controller 업데이트
- [ ] WebSocket Event Listener
- [ ] 메시지 저장/캐싱 로직

### Week 4: Slack 기능
- [ ] Workspace CRUD API
- [ ] Channel CRUD API
- [ ] User Presence Service
- [ ] 멤버 관리 기능

### Week 5: UI/UX
- [ ] Slack 스타일 HTML/CSS
- [ ] JavaScript 클라이언트
- [ ] 실시간 업데이트 UI
- [ ] 에러 핸들링 및 로딩 상태

### Week 6: 테스트 & 최적화
- [ ] 단위 테스트 작성
- [ ] 통합 테스트 작성
- [ ] 성능 최적화
- [ ] 문서화

---

## 13. 추가 기능 아이디어 (선택사항)

### 13.1 고급 기능
- **파일 업로드**: 이미지, 문서 첨부
- **스레드 답글**: 메시지에 대한 답글 스레드
- **메시지 반응**: 이모지 반응 기능
- **검색**: 메시지/파일 검색
- **알림**: 웹 푸시 알림
- **멘션**: @사용자명 멘션
- **다크 모드**: UI 테마 전환

### 13.2 관리 기능
- **관리자 패널**: 워크스페이스 관리
- **통계**: 사용량 통계
- **감사 로그**: 활동 기록
- **권한 관리**: 역할 기반 접근 제어

---

## 마무리

이 문서는 Slack 스타일 채팅 앱을 구현하기 위한 전체 로드맵입니다.
각 섹션은 독립적으로 구현 가능하도록 설계되었으며,
순차적으로 진행하면 약 6주 내에 완성할 수 있습니다.

**주요 포인트:**
✅ 기존 H2/JPA 코드는 유지하면서 확장
✅ JMS로 메시지 안정성 확보
✅ 인메모리 캐시로 성능 최적화
✅ OAuth로 간편한 인증
✅ Slack 수준의 UX 제공

질문이나 추가 설명이 필요한 부분이 있으면 언제든 문의해주세요!
