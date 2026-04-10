import json


class Chapter:
    def __init__(self, text: str, title: str, number: int):
        self.title = title
        self.number = number
        self.text = text

    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "number": self.number,
            "text": self.text
        }

class Character:
    def __init__(self, name: str, age: int | str = None, description: str = None, tags: list[str] = None):
        self.name = name
        self.age = age
        self.description = description
        self.tags = tags if tags is not None else []

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "age": self.age,
            "description": self.description,
            "tags": self.tags
        }
    
class CharacterRelation:
    def __init__(self, character1: Character, character2: Character, relation_type: str):
        self.character1 = character1
        self.character2 = character2
        self.relation_type = relation_type

    def to_dict(self) -> dict:
        return {
            "character1": self.character1.name,
            "character2": self.character2.name,
            "relation_type": self.relation_type
        }

class Event:
    """An event on a timeline.  Stores y_pos/height for visual layout
    and a derived 'time' string read from the vertical axis markers."""
    def __init__(self, description: str, characters_involved: list = None,
                 location=None, time: str = None,
                 y_pos: float = 0, height: float = 60):
        self.description = description
        self.characters_involved = characters_involved if characters_involved is not None else []
        self.location = location
        self.time = time
        self.y_pos = y_pos
        self.height = height

    def to_dict(self) -> dict:
        return {
            "description": self.description,
            "characters_involved": [
                (c.name if hasattr(c, "name") else c)
                for c in self.characters_involved
            ],
            "location": self.location.name if self.location and hasattr(self.location, "name") else self.location,
            "time": self.time,
            "y_pos": self.y_pos,
            "height": self.height,
        }


class EventOrder:
    """A timeline view with character columns and configurable time markers."""
    def __init__(self, name: str = "Event Order", character_columns: list = None,
                 timeline_config: dict = None):
        self.name = name
        self.character_columns = character_columns if character_columns is not None else []
        self.timeline_config = timeline_config if timeline_config is not None else {
            "mode": "custom",
            "pixels_per_marker": 80,
            "custom_labels": ["Start", "Middle", "End"],
        }
    
    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "character_columns": self.character_columns,
            "timeline_config": self.timeline_config,
        }

class Location:
    def __init__(self, name: str, description: str = None,
                 width: float = 10.0, height: float = 10.0, unit: str = "m",
                 objects: list = None):
        self.name = name
        self.description = description
        self.width = width
        self.height = height
        self.unit = unit
        self.objects = objects if objects is not None else []

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "description": self.description,
            "width": self.width,
            "height": self.height,
            "unit": self.unit,
            "objects": [o.to_dict() if hasattr(o, "to_dict") else o for o in self.objects],
        }

class LocationObject:
    """A drawable object placed on a Location map.

    type: rectangle | ellipse | circle | tree | house | castle | car |
          lake | road | sand | garden
    For shapes (rect/ellipse/circle): x, y, width, height, color, stroke
    For icons (tree/house/castle/car): x, y, scale, color
    For areas (lake/road/sand/garden): points list, color, stroke, stroke_width
    """
    def __init__(self, obj_type: str = "rectangle", name: str = "",
                 x: float = 0, y: float = 0,
                 width: float = 60, height: float = 40,
                 color: str = "#cccccc", stroke: str = "#666666",
                 stroke_width: float = 2,
                 points: list = None, scale: float = 1.0):
        self.obj_type = obj_type
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.color = color
        self.stroke = stroke
        self.stroke_width = stroke_width
        self.points = points if points is not None else []
        self.scale = scale

    def to_dict(self) -> dict:
        return {
            "type": self.obj_type,
            "name": self.name,
            "x": self.x,
            "y": self.y,
            "width": self.width,
            "height": self.height,
            "color": self.color,
            "stroke": self.stroke,
            "stroke_width": self.stroke_width,
            "points": self.points,
            "scale": self.scale,
        }

class Question:
    def __init__(self, text: str, answer: str | None = None, answered: bool = False):
        self.text = text
        self.answer = answer
        self.answered = answered
    
    @property
    def is_answered(self) -> bool:
        return self.answered

    def to_dict(self) -> dict:
        return {
            "text": self.text,
            "answer": self.answer,
            "answered": self.answered,
        }
    
class Topic:
    def __init__(self, name: str, questions: list[Question] = None, items: list[str] | None = None, url_links: list[str] | None = None):
        self.name = name
        self.questions = questions if questions is not None else []
        self.items = items if items is not None else []
        self.url_links = url_links if url_links is not None else []
    
    def add_question(self, question: Question):
        self.questions.append(question)

    def add_item(self, item: str):
        self.items.append(item)
    
    def add_url_link(self, url_link: str):
        self.url_links.append(url_link)

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "questions": [question.to_dict() for question in self.questions],
            "items": self.items,
            "url_links": self.url_links
        }

class Book:
    def __init__(self, title: str, author: str, chapters: list[Chapter] = None,
                 characters: list[Character] = None, locations: list[Location] = None,
                 questions: list[Question] = None, event_orders: list[EventOrder] = None,
                 character_relations: list[CharacterRelation] = None,
                 canvas_nodes: list[dict] = None,
                 topics: list[Topic] = None,
                 tags: list[str] = None):
        self.title = title
        self.author = author
        self.chapters = chapters if chapters is not None else []
        self.characters = characters if characters is not None else []
        self.locations = locations if locations is not None else []
        self.event_orders = event_orders if event_orders is not None else []
        self.questions = questions if questions is not None else []
        self.character_relations = character_relations if character_relations is not None else []
        self.canvas_nodes = canvas_nodes if canvas_nodes is not None else []
        self.topics = topics if topics is not None else []
        self.tags = tags if tags is not None else []

    def add_character(self, character: Character):
        self.characters.append(character)

    def add_location(self, location: Location):
        self.locations.append(location)

    def add_question(self, question: Question):
        self.questions.append(question)
    
    def add_event_order(self, event_order: EventOrder):
        self.event_orders.append(event_order)

    def add_topic(self, topic: Topic):
        self.topics.append(topic)

    def add_tag(self, tag: str):
        self.tags.append(tag)

    def add_character_relation(self, relation: CharacterRelation):
        self.character_relations.append(relation)

    def add_canvas_node(self, node: dict):
        self.canvas_nodes.append(node)


    def get_character_by_name(self, name: str) -> Character | None:
        for character in self.characters:
            if character.name == name:
                return character
        return None
    
    def get_location_by_name(self, name: str) -> Location | None:
        for location in self.locations:
            if location.name == name:
                return location
        return None
    
    @property
    def text(self) -> str:
        return "\n".join(chapter.title + "\n" + chapter.text for chapter in self.chapters)
    
    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "author": self.author,
            "chapters": [chapter.to_dict() for chapter in self.chapters],
            "characters": [character.to_dict() for character in self.characters],
            "locations": [loc.to_dict() for loc in self.locations],
            "questions": [question.to_dict() for question in self.questions],
            "event_orders": [eo.to_dict() for eo in self.event_orders],
            "character_relations": [cr.to_dict() for cr in self.character_relations],
            "canvas_nodes": self.canvas_nodes,
            "topics": [topic.to_dict() for topic in self.topics],
            "tags": self.tags,

        }
    
    def to_json(self) -> str:
        return json.dumps(self.to_dict(), indent=4)
