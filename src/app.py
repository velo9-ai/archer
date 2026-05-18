"""Archer FastAPI application factory."""
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates


def create_app() -> FastAPI:
    app = FastAPI(title="Archer", version="0.1.0")

    # TODO: register routes
    # from src.api.routes import dashboard, repos, runs, chat
    # app.include_router(dashboard.router)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    return app


app = create_app()
