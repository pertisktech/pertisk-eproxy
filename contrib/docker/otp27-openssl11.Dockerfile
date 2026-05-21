FROM almalinux:8

ARG OTP_REF=maint-27

RUN dnf install -y epel-release && \
    dnf install -y \
      git curl ca-certificates make gcc gcc-c++ perl \
      ncurses-devel openssl-devel autoconf automake libtool \
      unixODBC-devel wxBase wxGTK3-devel tar which findutils && \
    dnf clean all

# Build OTP 27 against system OpenSSL 1.1 (AlmaLinux 8).
RUN git clone --depth 1 --branch ${OTP_REF} https://github.com/erlang/otp.git /tmp/otp && \
    cd /tmp/otp && \
    ./otp_build autoconf && \
    ./configure --prefix=/usr/local/otp27 --with-ssl=/usr && \
    make -j"$(nproc)" && \
    make install && \
    /usr/local/otp27/bin/erl -noshell -eval 'io:format("OTP=~s~n", [erlang:system_info(otp_release)]), init:stop().' && \
    rm -rf /tmp/otp

RUN ln -s /usr/local/otp27/bin/erl /usr/local/bin/erl && \
    ln -s /usr/local/otp27/bin/erlc /usr/local/bin/erlc && \
    ln -s /usr/local/otp27/bin/escript /usr/local/bin/escript

RUN curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 && \
    chmod +x /usr/local/bin/rebar3

ENV PATH="/usr/local/otp27/bin:${PATH}"
